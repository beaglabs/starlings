use std::collections::HashSet;
use std::env;
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use futures_util::{Stream, StreamExt};
use p2panda::streams::{Source, StreamEvent, StreamPublisher, StreamSubscription};
use p2panda::{Node, Topic};
use serde::{Deserialize, Serialize};
use tokio::task::JoinSet;
use tokio::time::{interval, sleep, timeout, MissedTickBehavior};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct FfiAction {
    selected: u16,
    next_cursor: u16,
    reset_sent: u8,
    _padding: [u8; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct FfiSimulation {
    success: u8,
    _padding: [u8; 7],
    rounds: u32,
    _padding2: u32,
    communication_units: u64,
    useful_deliveries: u64,
    duplicate_deliveries: u64,
    policy_calls: u64,
    violations: u64,
}

unsafe extern "C" {
    fn starlings_stage7c_abi_version() -> u32;

    fn starlings_stage7c_init_state(
        population_size: u16,
        fact_count: u16,
        topology: u8,
        redundancy: u16,
        bandwidth: u16,
        seed: u64,
        operator_index: u16,
        out_knowledge: *mut u64,
        out_words: usize,
    ) -> i32;

    fn starlings_stage7c_decide(
        population_size: u16,
        fact_count: u16,
        topology: u8,
        redundancy: u16,
        bandwidth: u16,
        seed: u64,
        operator_index: u16,
        round: u32,
        cursor: u16,
        novelty_permille: u16,
        exploration_permille: u16,
        retry_permille: u16,
        bandwidth_utilization_permille: u16,
        knowledge_words: *const u64,
        sent_words: *const u64,
        input_words: usize,
        out_fact_words: *mut u64,
        out_words: usize,
        out_action: *mut FfiAction,
    ) -> i32;

    fn starlings_stage7c_simulate(
        population_size: u16,
        fact_count: u16,
        topology: u8,
        redundancy: u16,
        bandwidth: u16,
        seed: u64,
        max_rounds: u32,
        novelty_permille: u16,
        exploration_permille: u16,
        retry_permille: u16,
        bandwidth_utilization_permille: u16,
        out_simulation: *mut FfiSimulation,
    ) -> i32;
}

const ABI_VERSION: u32 = 1;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(30);
const OPERATION_TIMEOUT: Duration = Duration::from_secs(10);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

async fn bounded<T>(
    phase: &str,
    limit: Duration,
    future: impl Future<Output = Result<T>>,
) -> Result<T> {
    timeout(limit, future)
        .await
        .with_context(|| format!("{phase}: timed out after {limit:?}"))?
        .with_context(|| phase.to_owned())
}

async fn receive_while<F, S, H, T>(
    operation: F,
    rx: &mut S,
    stop: &AtomicBool,
    mut on_event: H,
) -> Result<Option<T>>
where
    F: Future<Output = Result<T>>,
    S: Stream + Unpin,
    H: FnMut(S::Item) -> Result<()>,
{
    tokio::pin!(operation);
    let mut cancellation = interval(Duration::from_millis(10));
    loop {
        if stop.load(Ordering::Acquire) {
            return Ok(None);
        }
        tokio::select! {
            biased;
            _ = cancellation.tick() => {}
            result = &mut operation => return result.map(Some),
            event = rx.next() => {
                let event = event.context("topic stream closed while publishing")?;
                on_event(event)?;
            }
        }
    }
}

async fn collect_nodes(
    mut tasks: JoinSet<Result<NodeStats>>,
    stop: &AtomicBool,
    collector_complete: &AtomicBool,
    max_runtime: Duration,
    drain: Duration,
    shutdown: Duration,
) -> Result<Vec<NodeStats>> {
    let deadline = sleep(max_runtime);
    tokio::pin!(deadline);
    let mut poll = interval(Duration::from_millis(10));
    let mut progress = interval(Duration::from_secs(2));
    let mut stats = Vec::with_capacity(tasks.len());
    while !tasks.is_empty() {
        tokio::select! {
            biased;
            _ = &mut deadline => {
                eprintln!("[stop] runtime deadline reached");
                break;
            }
            result = tasks.join_next() => {
                stats.push(result.context("missing node task")?
                    .context("join Stage 7C node task")??);
            }
            _ = poll.tick() => {
                if stop.load(Ordering::Acquire) {
                    bail!("Stage 7C node requested stop after a policy error");
                }
                if collector_complete.load(Ordering::Acquire) {
                    eprintln!("[drain] collector has all facts");
                    sleep(drain).await;
                    break;
                }
            }
            _ = progress.tick() => {
                eprintln!("[running] {} node tasks active; collector_complete={}",
                    tasks.len(), collector_complete.load(Ordering::Acquire));
            }
        }
    }
    stop.store(true, Ordering::Release);
    bounded("node shutdown", shutdown, async {
        while let Some(result) = tasks.join_next().await {
            stats.push(result.context("join Stage 7C node task")??);
        }
        Ok(())
    }).await?;
    Ok(stats)
}

#[derive(Clone, Copy, Debug)]
struct Theta {
    novelty: u16,
    exploration: u16,
    retry: u16,
    utilization: u16,
}

#[derive(Clone, Copy, Debug)]
enum Topology {
    Ring,
    Complete,
    Grid,
}

impl Topology {
    fn code(self) -> u8 {
        match self {
            Self::Ring => 0,
            Self::Complete => 1,
            Self::Grid => 2,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Ring => "ring",
            Self::Complete => "complete",
            Self::Grid => "grid",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value {
            "ring" => Ok(Self::Ring),
            "complete" => Ok(Self::Complete),
            "grid" => Ok(Self::Grid),
            _ => bail!("unknown topology {value:?}; use ring|complete|grid"),
        }
    }
}

#[derive(Clone, Debug)]
struct Config {
    profile: String,
    theta: Theta,
    nodes: u16,
    facts: u16,
    topology: Topology,
    redundancy: u16,
    bandwidth: u16,
    seed: u64,
    tick_ms: u64,
    startup_ms: u64,
    drain_ms: u64,
    max_ticks: u32,
    sim_max_rounds: u32,
    no_header: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            profile: "theta51".into(),
            theta: profile_theta("theta51").unwrap(),
            nodes: 8,
            facts: 32,
            topology: Topology::Ring,
            redundancy: 2,
            bandwidth: 2,
            seed: 0,
            tick_ms: 20,
            startup_ms: 1000,
            drain_ms: 500,
            max_ticks: 1024,
            sim_max_rounds: 4096,
            no_header: false,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Envelope {
    run_nonce: u64,
    sender: u16,
    sequence: u32,
    logical_round: u32,
    recipients: Vec<u16>,
    facts: Vec<u16>,
}

#[derive(Debug)]
struct LocalState {
    knowledge: Vec<u64>,
    sent: Vec<u64>,
    cursor: u16,
    round: u32,
    sequence: u32,
}

#[derive(Clone, Debug, Default)]
struct NodeStats {
    node: u16,
    initial_facts: usize,
    final_facts: usize,
    rounds: u32,
    actions: u64,
    logical_messages: u64,
    communication_units: u64,
    useful_deliveries: u64,
    duplicate_deliveries: u64,
    p2panda_local_operations: u64,
    p2panda_remote_operations: u64,
    duplicate_envelopes: u64,
    sync_sessions: u64,
    sync_sent_bytes: u64,
    sync_received_bytes: u64,
    sync_errors: u64,
    policy_errors: u64,
    collector_complete: bool,
}

#[derive(Debug, Default)]
struct AggregateStats {
    actions: u64,
    logical_messages: u64,
    communication_units: u64,
    useful_deliveries: u64,
    duplicate_deliveries: u64,
    p2panda_local_operations: u64,
    p2panda_remote_operations: u64,
    duplicate_envelopes: u64,
    sync_sessions: u64,
    sync_sent_bytes: u64,
    sync_received_bytes: u64,
    sync_errors: u64,
    policy_errors: u64,
    max_local_round: u32,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let config = parse_args()?;

    let abi = unsafe { starlings_stage7c_abi_version() };
    if abi != ABI_VERSION {
        bail!("Stage 7C ABI mismatch: Rust expects {ABI_VERSION}, Zig reports {abi}");
    }

    validate_config(&config)?;

    let simulation = simulate(&config)?;
    if simulation.violations != 0 {
        bail!(
            "synchronous Stage 7A baseline reported {} violations",
            simulation.violations
        );
    }

    let topic = Topic::random();
    let run_nonce = run_nonce(&config);
    eprintln!(
        "Stage 7C P2Panda transfer: profile={} theta=({},{},{},{}) N={} F={} G={} R={} B={} seed={} topic={}",
        config.profile,
        config.theta.novelty,
        config.theta.exploration,
        config.theta.retry,
        config.theta.utilization,
        config.nodes,
        config.facts,
        config.topology.name(),
        config.redundancy,
        config.bandwidth,
        config.seed,
        topic,
    );

    let mut node_guards: Vec<Node> = Vec::with_capacity(config.nodes as usize);
    let mut streams: Vec<(
        StreamPublisher<Envelope>,
        StreamSubscription<Envelope>,
    )> = Vec::with_capacity(config.nodes as usize);

    for node_index in 0..config.nodes {
        eprintln!("[spawn {}/{}] p2panda node", node_index + 1, config.nodes);
        let node = bounded(
            &format!("spawn p2panda node {node_index}"),
            STARTUP_TIMEOUT,
            async { Ok(p2panda::spawn().await?) },
        ).await?;
        eprintln!("[stream {}/{}] creating topic stream", node_index + 1, config.nodes);
        let pair = bounded(
            &format!("create topic stream for node {node_index}"),
            STARTUP_TIMEOUT,
            async { Ok(node.stream::<Envelope>(topic.clone()).await?) },
        ).await?;
        eprintln!("[ready {}/{}] node and stream initialized", node_index + 1, config.nodes);
        node_guards.push(node);
        streams.push(pair);
    }

    sleep(Duration::from_millis(config.startup_ms)).await;

    let stop = Arc::new(AtomicBool::new(false));
    let collector_complete = Arc::new(AtomicBool::new(false));
    let started = Instant::now();

    let mut handles = JoinSet::new();
    for (node_index, (tx, rx)) in streams.into_iter().enumerate() {
        let node_config = config.clone();
        let node_stop = stop.clone();
        let node_collector_complete = collector_complete.clone();
        handles.spawn(async move {
            run_node(
                node_index as u16,
                node_config,
                run_nonce,
                tx,
                rx,
                node_stop,
                node_collector_complete,
            )
            .await
        });
    }

    let max_runtime = Duration::from_millis(
        config.tick_ms.saturating_mul(config.max_ticks as u64)
            .saturating_add(config.startup_ms)
            .saturating_add(config.drain_ms)
            .saturating_add(5000),
    );

    let mut node_stats = collect_nodes(
        handles,
        &stop,
        &collector_complete,
        max_runtime,
        Duration::from_millis(config.drain_ms),
        SHUTDOWN_TIMEOUT,
    ).await?;
    node_stats.sort_by_key(|stats| stats.node);

    // Keep nodes alive through all stream processing and task joins.
    drop(node_guards);

    let collector = node_stats
        .iter()
        .find(|stats| stats.node == 0)
        .context("collector stats missing")?;
    let aggregate = aggregate(&node_stats);
    let elapsed_ms = started.elapsed().as_millis();

    if !config.no_header {
        println!(
            "profile\tn\te\tr\tu\tnodes\tfacts\ttopology\tredundancy\tbandwidth\tseed\tsim_success\tsim_rounds\tsim_communication\tdist_success\tdist_elapsed_ms\tcollector_initial\tcollector_final\tmax_local_round\tactions\tlogical_messages\tcommunication_units\tuseful\tduplicate\tundelivered_units\tp2panda_local_ops\tp2panda_remote_ops\tduplicate_envelopes\tsync_sessions\tsync_sent_bytes\tsync_received_bytes\tsync_errors\tpolicy_errors"
        );
    }

    println!(
        "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
        config.profile,
        config.theta.novelty,
        config.theta.exploration,
        config.theta.retry,
        config.theta.utilization,
        config.nodes,
        config.facts,
        config.topology.name(),
        config.redundancy,
        config.bandwidth,
        config.seed,
        yes_no(simulation.success != 0),
        simulation.rounds,
        simulation.communication_units,
        yes_no(collector.collector_complete),
        elapsed_ms,
        collector.initial_facts,
        collector.final_facts,
        aggregate.max_local_round,
        aggregate.actions,
        aggregate.logical_messages,
        aggregate.communication_units,
        aggregate.useful_deliveries,
        aggregate.duplicate_deliveries,
        aggregate.communication_units.saturating_sub(
            aggregate.useful_deliveries + aggregate.duplicate_deliveries,
        ),
        aggregate.p2panda_local_operations,
        aggregate.p2panda_remote_operations,
        aggregate.duplicate_envelopes,
        aggregate.sync_sessions,
        aggregate.sync_sent_bytes,
        aggregate.sync_received_bytes,
        aggregate.sync_errors,
        aggregate.policy_errors,
    );

    if aggregate.policy_errors != 0 {
        bail!("Stage 7C policy FFI reported errors");
    }

    if !collector.collector_complete {
        bail!("Stage 7C did not converge: collector has {}/{} facts",
            collector.final_facts, config.facts);
    }

    Ok(())
}

async fn run_node(
    node_index: u16,
    config: Config,
    run_nonce: u64,
    tx: StreamPublisher<Envelope>,
    mut rx: StreamSubscription<Envelope>,
    stop: Arc<AtomicBool>,
    collector_complete: Arc<AtomicBool>,
) -> Result<NodeStats> {
    let words = active_words(config.facts);
    let mut knowledge = vec![0_u64; words];

    let init_status = unsafe {
        starlings_stage7c_init_state(
            config.nodes,
            config.facts,
            config.topology.code(),
            config.redundancy,
            config.bandwidth,
            config.seed,
            node_index,
            knowledge.as_mut_ptr(),
            knowledge.len(),
        )
    };
    if init_status != 0 {
        bail!("node {node_index}: Zig state initialization failed with {init_status}");
    }

    let mut state = LocalState {
        knowledge,
        sent: vec![0_u64; words],
        cursor: 0,
        round: 0,
        sequence: 0,
    };

    let mut stats = NodeStats {
        node: node_index,
        initial_facts: count_facts(&state.knowledge, config.facts),
        ..NodeStats::default()
    };

    if node_index == 0 && contains_all(&state.knowledge, config.facts) {
        stats.collector_complete = true;
        collector_complete.store(true, Ordering::Release);
    }

    let mut seen: HashSet<(u64, u16, u32)> = HashSet::new();
    let mut ticker = interval(Duration::from_millis(config.tick_ms));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut emission_done = false;
    let mut cancellation = interval(Duration::from_millis(10));

    while !stop.load(Ordering::Acquire) {
        tokio::select! {
            _ = cancellation.tick() => {}
            _ = ticker.tick() => {
                if emission_done {
                    continue;
                }
                if state.round >= config.max_ticks {
                    emission_done = true;
                    continue;
                }

                state.round += 1;
                stats.rounds = state.round;

                let mut output_words = vec![0_u64; words];
                let mut action = FfiAction::default();
                let status = unsafe {
                    starlings_stage7c_decide(
                        config.nodes,
                        config.facts,
                        config.topology.code(),
                        config.redundancy,
                        config.bandwidth,
                        config.seed,
                        node_index,
                        state.round,
                        state.cursor,
                        config.theta.novelty,
                        config.theta.exploration,
                        config.theta.retry,
                        config.theta.utilization,
                        state.knowledge.as_ptr(),
                        state.sent.as_ptr(),
                        words,
                        output_words.as_mut_ptr(),
                        words,
                        &mut action,
                    )
                };

                if status < 0 {
                    stats.policy_errors += 1;
                    stop.store(true, Ordering::Release);
                    continue;
                }

                if status == 0 || action.selected == 0 {
                    continue;
                }

                let facts = words_to_facts(&output_words, config.facts);
                if facts.len() != action.selected as usize {
                    stats.policy_errors += 1;
                    stop.store(true, Ordering::Release);
                    continue;
                }

                let recipients = recipients(
                    config.topology,
                    node_index,
                    config.nodes,
                );

                state.sequence = state.sequence.wrapping_add(1);
                let envelope = Envelope {
                    run_nonce,
                    sender: node_index,
                    sequence: state.sequence,
                    logical_round: state.round,
                    recipients: recipients.clone(),
                    facts: facts.clone(),
                };

                let operation = async {
                    let processing = bounded(
                        &format!("node {node_index}: publish"),
                        OPERATION_TIMEOUT,
                        async { Ok(tx.publish(envelope).await?) },
                    ).await?;
                    let processed = bounded(
                        &format!("node {node_index}: local processing"),
                        OPERATION_TIMEOUT,
                        async { Ok(processing.await?) },
                    ).await?;
                    if processed.is_failed() {
                        bail!("node {node_index}: local processing failed: {:?}",
                            processed.failure_reason());
                    }
                    Ok(())
                };
                if receive_while(operation, &mut rx, &stop, |event| {
                    apply_event(event, node_index, &config, run_nonce,
                        &mut state, &mut stats, &mut seen, &collector_complete)
                }).await?.is_none() {
                    break;
                }

                if action.reset_sent != 0 {
                    state.sent.fill(0);
                }
                for fact in &facts {
                    set_fact(&mut state.sent, *fact);
                }
                state.cursor = action.next_cursor;

                stats.actions += 1;
                stats.logical_messages += recipients.len() as u64;
                stats.communication_units +=
                    (facts.len() as u64) * (recipients.len() as u64);
            }

            event = rx.next() => {
                let event = event.context("topic stream closed before run completed")?;
                apply_event(event, node_index, &config, run_nonce,
                    &mut state, &mut stats, &mut seen, &collector_complete)?;
            }
        }
    }

    stats.final_facts = count_facts(&state.knowledge, config.facts);
    if node_index == 0 {
        stats.collector_complete = contains_all(&state.knowledge, config.facts);
    }

    Ok(stats)
}

fn apply_event(
    event: StreamEvent<Envelope>,
    node_index: u16,
    config: &Config,
    run_nonce: u64,
    state: &mut LocalState,
    stats: &mut NodeStats,
    seen: &mut HashSet<(u64, u16, u32)>,
    collector_complete: &AtomicBool,
) -> Result<()> {
    match event {
        StreamEvent::Processed { operation, source } => {
            match source {
                Source::LocalStore => {
                    stats.p2panda_local_operations += 1;
                }
                Source::SyncSession { .. } => {
                    stats.p2panda_remote_operations += 1;
                }
                Source::ExternalStream { .. } => {}
            }

            let envelope = operation.message();
            if envelope.run_nonce != run_nonce {
                return Ok(());
            }

            let key = (
                envelope.run_nonce,
                envelope.sender,
                envelope.sequence,
            );
            if !seen.insert(key) {
                stats.duplicate_envelopes += 1;
                return Ok(());
            }

            if !envelope.recipients.contains(&node_index) {
                return Ok(());
            }

            for fact in &envelope.facts {
                if has_fact(&state.knowledge, *fact) {
                    stats.duplicate_deliveries += 1;
                } else {
                    stats.useful_deliveries += 1;
                    set_fact(&mut state.knowledge, *fact);
                }
            }

            if node_index == 0
                && contains_all(&state.knowledge, config.facts)
            {
                stats.collector_complete = true;
                collector_complete.store(true, Ordering::Release);
            }
        }

        StreamEvent::SyncEnded {
            sent_bytes,
            received_bytes,
            error,
            ..
        } => {
            stats.sync_sessions += 1;
            stats.sync_sent_bytes += sent_bytes as u64;
            stats.sync_received_bytes += received_bytes as u64;
            if error.is_some() {
                stats.sync_errors += 1;
            }
        }

        StreamEvent::ProcessingFailed { .. }
        | StreamEvent::ReplayFailed { .. }
        | StreamEvent::DecodeFailed { .. }
        | StreamEvent::AckFailed { .. } => {
            stats.sync_errors += 1;
        }

        _ => {}
    }
    Ok(())
}

fn simulate(config: &Config) -> Result<FfiSimulation> {
    let mut simulation = FfiSimulation::default();
    let status = unsafe {
        starlings_stage7c_simulate(
            config.nodes,
            config.facts,
            config.topology.code(),
            config.redundancy,
            config.bandwidth,
            config.seed,
            config.sim_max_rounds,
            config.theta.novelty,
            config.theta.exploration,
            config.theta.retry,
            config.theta.utilization,
            &mut simulation,
        )
    };
    if status != 0 {
        bail!("synchronous Stage 7A simulation failed with status {status}");
    }
    Ok(simulation)
}

fn aggregate(nodes: &[NodeStats]) -> AggregateStats {
    let mut total = AggregateStats::default();
    for stats in nodes {
        total.actions += stats.actions;
        total.logical_messages += stats.logical_messages;
        total.communication_units += stats.communication_units;
        total.useful_deliveries += stats.useful_deliveries;
        total.duplicate_deliveries += stats.duplicate_deliveries;
        total.p2panda_local_operations += stats.p2panda_local_operations;
        total.p2panda_remote_operations += stats.p2panda_remote_operations;
        total.duplicate_envelopes += stats.duplicate_envelopes;
        total.sync_sessions += stats.sync_sessions;
        total.sync_sent_bytes += stats.sync_sent_bytes;
        total.sync_received_bytes += stats.sync_received_bytes;
        total.sync_errors += stats.sync_errors;
        total.policy_errors += stats.policy_errors;
        total.max_local_round = total.max_local_round.max(stats.rounds);
    }
    total
}

fn recipients(
    topology: Topology,
    sender: u16,
    population: u16,
) -> Vec<u16> {
    match topology {
        Topology::Ring => {
            let left = (sender + population - 1) % population;
            let right = (sender + 1) % population;
            if left == right {
                vec![left]
            } else {
                vec![left, right]
            }
        }
        Topology::Complete => (0..population)
            .filter(|candidate| *candidate != sender)
            .collect(),
        Topology::Grid => {
            let width = grid_width(population as usize);
            let sender_usize = sender as usize;
            let row = sender_usize / width;
            let col = sender_usize % width;
            let mut result = Vec::with_capacity(4);

            if col > 0 {
                result.push((sender_usize - 1) as u16);
            }
            if col + 1 < width && sender_usize + 1 < population as usize {
                let recipient = sender_usize + 1;
                if recipient / width == row {
                    result.push(recipient as u16);
                }
            }
            if sender_usize >= width {
                result.push((sender_usize - width) as u16);
            }
            if sender_usize + width < population as usize {
                result.push((sender_usize + width) as u16);
            }

            result
        }
    }
}

fn grid_width(population: usize) -> usize {
    let mut width = 1;
    while width * width < population {
        width += 1;
    }
    width
}

fn active_words(facts: u16) -> usize {
    (facts as usize + 63) / 64
}

fn has_fact(words: &[u64], fact: u16) -> bool {
    let index = fact as usize;
    (words[index / 64] & (1_u64 << (index % 64))) != 0
}

fn set_fact(words: &mut [u64], fact: u16) {
    let index = fact as usize;
    words[index / 64] |= 1_u64 << (index % 64);
}

fn words_to_facts(words: &[u64], fact_count: u16) -> Vec<u16> {
    (0..fact_count)
        .filter(|fact| has_fact(words, *fact))
        .collect()
}

fn count_facts(words: &[u64], fact_count: u16) -> usize {
    (0..fact_count)
        .filter(|fact| has_fact(words, *fact))
        .count()
}

fn contains_all(words: &[u64], fact_count: u16) -> bool {
    count_facts(words, fact_count) == fact_count as usize
}

fn profile_theta(name: &str) -> Option<Theta> {
    match name {
        "theta37" => Some(Theta {
            novelty: 244,
            exploration: 94,
            retry: 15,
            utilization: 958,
        }),
        "theta51" => Some(Theta {
            novelty: 354,
            exploration: 141,
            retry: 0,
            utilization: 994,
        }),
        "theta93" => Some(Theta {
            novelty: 685,
            exploration: 283,
            retry: 960,
            utilization: 344,
        }),
        "round_robin" => Some(Theta {
            novelty: 0,
            exploration: 0,
            retry: 1000,
            utilization: 1000,
        }),
        "seeded" => Some(Theta {
            novelty: 0,
            exploration: 1000,
            retry: 1000,
            utilization: 1000,
        }),
        "novel_first" => Some(Theta {
            novelty: 1000,
            exploration: 0,
            retry: 0,
            utilization: 1000,
        }),
        _ => None,
    }
}

fn parse_args() -> Result<Config> {
    let mut config = Config::default();
    let mut args = env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--profile" => {
                let value = next_value(&mut args, "--profile")?;
                config.theta = profile_theta(&value).with_context(|| {
                    format!(
                        "unknown profile {value:?}; use theta37|theta51|theta93|round_robin|seeded|novel_first"
                    )
                })?;
                config.profile = value;
            }
            "--nodes" => {
                config.nodes = next_value(&mut args, "--nodes")?.parse()?;
            }
            "--facts" => {
                config.facts = next_value(&mut args, "--facts")?.parse()?;
            }
            "--topology" => {
                config.topology =
                    Topology::parse(&next_value(&mut args, "--topology")?)?;
            }
            "--redundancy" => {
                config.redundancy =
                    next_value(&mut args, "--redundancy")?.parse()?;
            }
            "--bandwidth" => {
                config.bandwidth =
                    next_value(&mut args, "--bandwidth")?.parse()?;
            }
            "--seed" => {
                config.seed = next_value(&mut args, "--seed")?.parse()?;
            }
            "--tick-ms" => {
                config.tick_ms =
                    next_value(&mut args, "--tick-ms")?.parse()?;
            }
            "--startup-ms" => {
                config.startup_ms =
                    next_value(&mut args, "--startup-ms")?.parse()?;
            }
            "--drain-ms" => {
                config.drain_ms =
                    next_value(&mut args, "--drain-ms")?.parse()?;
            }
            "--max-ticks" => {
                config.max_ticks =
                    next_value(&mut args, "--max-ticks")?.parse()?;
            }
            "--sim-max-rounds" => {
                config.sim_max_rounds =
                    next_value(&mut args, "--sim-max-rounds")?.parse()?;
            }
            "--no-header" => {
                config.no_header = true;
            }
            "-h" | "--help" => {
                print_help();
                std::process::exit(0);
            }
            _ => bail!("unknown argument {arg:?}; use --help"),
        }
    }

    Ok(config)
}

fn next_value(
    args: &mut impl Iterator<Item = String>,
    flag: &str,
) -> Result<String> {
    args.next()
        .with_context(|| format!("missing value after {flag}"))
}

fn validate_config(config: &Config) -> Result<()> {
    if config.nodes < 2 || config.nodes > 1024 {
        bail!("nodes must be in 2..=1024");
    }
    if config.facts == 0 || config.facts > 2048 {
        bail!("facts must be in 1..=2048");
    }
    if config.redundancy == 0 || config.redundancy > config.nodes {
        bail!("redundancy must be in 1..=nodes");
    }
    if config.bandwidth == 0 || config.bandwidth > config.facts {
        bail!("bandwidth must be in 1..=facts");
    }
    if config.tick_ms == 0 {
        bail!("tick-ms must be non-zero");
    }
    if config.max_ticks == 0 {
        bail!("max-ticks must be non-zero");
    }
    Ok(())
}

fn run_nonce(config: &Config) -> u64 {
    let mut value =
        config.seed
        ^ ((config.nodes as u64) << 48)
        ^ ((config.facts as u64) << 32)
        ^ ((config.redundancy as u64) << 24)
        ^ ((config.bandwidth as u64) << 16)
        ^ ((config.theta.novelty as u64) << 1)
        ^ ((config.theta.exploration as u64) << 11)
        ^ ((config.theta.retry as u64) << 21)
        ^ ((config.theta.utilization as u64) << 31)
        ^ (config.topology.code() as u64);

    value = value.wrapping_add(0x9e3779b97f4a7c15);
    value = (value ^ (value >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)).wrapping_mul(0x94d049bb133111eb);
    value ^ (value >> 31)
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn print_help() {
    eprintln!(
        "Stage 7C native P2Panda distributed-runtime transfer\n\n\
usage:\n  cargo run --release -- [options]\n\n\
options:\n\
  --profile theta37|theta51|theta93|round_robin|seeded|novel_first\n\
  --nodes N                 default 8\n\
  --facts F                 default 32\n\
  --topology ring|grid|complete\n\
  --redundancy R            default 2\n\
  --bandwidth B             default 2\n\
  --seed S                  default 0\n\
  --tick-ms MS              local policy tick, default 20\n\
  --startup-ms MS           discovery warm-up, default 1000\n\
  --drain-ms MS             in-flight drain after collector success, default 500\n\
  --max-ticks N             default 1024\n\
  --sim-max-rounds N        synchronous control horizon, default 4096\n\
  --no-header               emit only one TSV data row"
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_layout_matches_zig_contract() {
        assert_eq!(std::mem::size_of::<FfiAction>(), 8);
        assert_eq!(std::mem::size_of::<FfiSimulation>(), 56);
    }

    #[test]
    fn exact_stage7b_profiles_are_frozen() {
        let theta51 = profile_theta("theta51").unwrap();
        assert_eq!(theta51.novelty, 354);
        assert_eq!(theta51.exploration, 141);
        assert_eq!(theta51.retry, 0);
        assert_eq!(theta51.utilization, 994);

        let theta93 = profile_theta("theta93").unwrap();
        assert_eq!(theta93.novelty, 685);
        assert_eq!(theta93.exploration, 283);
        assert_eq!(theta93.retry, 960);
        assert_eq!(theta93.utilization, 344);
    }

    #[test]
    fn ring_recipients_match_stage5_semantics() {
        assert_eq!(recipients(Topology::Ring, 0, 5), vec![4, 1]);
        assert_eq!(recipients(Topology::Ring, 0, 2), vec![1]);
    }

    #[test]
    fn grid_recipients_match_stage5_semantics() {
        assert_eq!(recipients(Topology::Grid, 0, 9), vec![1, 3]);
        assert_eq!(recipients(Topology::Grid, 4, 9), vec![3, 5, 1, 7]);
    }

    #[tokio::test]
    async fn publication_drains_backpressure_before_waiting_for_ack() {
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        let mut rx = Box::pin(futures_util::stream::unfold(rx, |mut rx| async {
            rx.recv().await.map(|event| (event, rx))
        }));
        let (acked_tx, acked_rx) = tokio::sync::oneshot::channel();
        let mut acked_tx = Some(acked_tx);
        let mut received = Vec::new();
        let stop = AtomicBool::new(false);
        let operation = async {
            for event in 0..64 {
                tx.send(event).await?;
            }
            acked_rx.await?;
            Ok(())
        };
        let result = timeout(Duration::from_secs(2), receive_while(
            operation, &mut rx, &stop, |event| {
                received.push(event);
                if event == 63 {
                    acked_tx.take().unwrap().send(()).unwrap();
                }
                Ok(())
            },
        )).await.unwrap().unwrap();
        assert_eq!(result, Some(()));
        assert_eq!(received, (0..64).collect::<Vec<_>>());
    }

    #[tokio::test]
    async fn stalled_operation_times_out_with_phase_context() {
        for phase in ["spawn node", "create stream", "publish", "local processing"] {
            let mut rx = futures_util::stream::pending::<()>();
            let stop = AtomicBool::new(false);
            let result = timeout(Duration::from_secs(2), receive_while(
                bounded(phase, Duration::from_millis(5), std::future::pending::<Result<()>>()),
                &mut rx, &stop, |_| Ok(()),
            )).await.unwrap().unwrap_err();
            assert!(result.to_string().contains(phase));
            assert!(result.to_string().contains("timed out"));
        }
    }

    #[tokio::test]
    async fn stop_interrupts_pending_publication() {
        let stop = AtomicBool::new(false);
        let mut rx = futures_util::stream::pending::<()>();
        let cancel = async {
            sleep(Duration::from_millis(5)).await;
            stop.store(true, Ordering::Release);
        };
        let (_, result) = timeout(Duration::from_secs(2), async {
            tokio::join!(cancel, receive_while(
                std::future::pending::<Result<()>>(), &mut rx, &stop, |_| Ok(()),
            ))
        }).await.unwrap();
        assert_eq!(result.unwrap(), None);
    }

    #[tokio::test]
    async fn closed_stream_fails_pending_publication() {
        let mut rx = futures_util::stream::empty::<()>();
        let stop = AtomicBool::new(false);
        let error = receive_while(
            std::future::pending::<Result<()>>(), &mut rx, &stop, |_| Ok(()),
        ).await.unwrap_err();
        assert!(error.to_string().contains("topic stream closed"));
    }

    struct DropSignal(Arc<AtomicBool>);

    impl Drop for DropSignal {
        fn drop(&mut self) {
            self.0.store(true, Ordering::Release);
        }
    }

    #[tokio::test]
    async fn deadline_aborts_unresponsive_node_instead_of_hanging_on_join() {
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = DropSignal(dropped.clone());
        let mut tasks = JoinSet::new();
        tasks.spawn(async move {
            let _guard = guard;
            std::future::pending::<Result<NodeStats>>().await
        });
        let stop = AtomicBool::new(false);
        let complete = AtomicBool::new(false);
        let error = timeout(Duration::from_secs(2), collect_nodes(
            tasks, &stop, &complete, Duration::from_millis(5),
            Duration::ZERO, Duration::from_millis(5),
        )).await.unwrap().unwrap_err();
        assert!(error.to_string().contains("node shutdown"));
        assert!(stop.load(Ordering::Acquire));
        timeout(Duration::from_secs(2), async {
            while !dropped.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        }).await.unwrap();
    }

    #[tokio::test]
    async fn node_failure_is_reported_without_waiting_for_runtime_deadline() {
        let mut tasks = JoinSet::new();
        tasks.spawn(std::future::pending::<Result<NodeStats>>());
        tasks.spawn(async { bail!("publication failed") });
        let stop = AtomicBool::new(false);
        let complete = AtomicBool::new(false);
        let error = timeout(Duration::from_secs(2), collect_nodes(
            tasks, &stop, &complete, Duration::from_secs(60),
            Duration::ZERO, Duration::from_millis(5),
        )).await.unwrap().unwrap_err();
        assert!(format!("{error:#}").contains("publication failed"));
    }

}

