# Stage 7C — Native P2Panda Distributed Transfer

Stage 7C asks whether the compact control policies discovered in Stage 7B
survive transfer from the deterministic synchronous simulator into an actual
distributed local-first runtime.

The first Stage 7C question is deliberately narrow:

> If the exact same local pi_theta runs independently at each node against only
> its current local state, does the population still converge when delivery,
> synchronization, and node scheduling are asynchronous P2Panda behavior rather
> than a synchronous Starlings round?

This is a transfer experiment, not a new policy search.

## Frozen policy family

No Stage 7C result can change the Stage 7B-selected theta values.

~~~text
theta37 = (n=244, e=94,  r=15,  u=958)
theta51 = (n=354, e=141, r=0,   u=994)
theta93 = (n=685, e=283, r=960, u=344)
~~~

The exact handcrafted controls are also available:

~~~text
round_robin
seeded
novel_first
~~~

Stage 7C does not optimize or fine-tune any of these values.

Any optional distributed fine-tuning belongs after the frozen transfer result
has been measured.

## Why native Rust P2Panda

The canonical Stage 7C adapter uses the native P2Panda Node API directly:

~~~text
p2panda = 0.7.0
~~~

This avoids making the experiment depend on an additional language-binding
layer.

The native API gives the harness direct access to:

~~~text
Node
Topic
StreamPublisher
StreamSubscription
Processed operations
operation source
sync sessions
sent/received sync bytes
processing failures
replay/ack/decode failures
~~~

Those are exactly the measurements needed for a transfer experiment.

## Zig remains the source of truth

The Rust harness must not reimplement pi_theta.

The file src/stage7c_policy_ffi.zig exposes a small C ABI:

~~~text
starlings_stage7c_abi_version
starlings_stage7c_init_state
starlings_stage7c_decide
starlings_stage7c_simulate
~~~

### init_state

Uses the exact Stage 5/7 deterministic initial fact placement.

Rust receives only the resulting local knowledge bitset.

### decide

Accepts externally held local state:

~~~text
knowledge
sent history
cursor
operator index
local asynchronous round
N/F/G/R/B/seed
theta
~~~

and calls the exact Stage 7A policy.

The returned action contains:

~~~text
selected fact bitset
selected count
next cursor
reset-sent flag
~~~

### simulate

Runs the exact synchronous Stage 7A simulator for the same:

~~~text
world
theta
seed
horizon
~~~

before the P2Panda run.

Therefore every Stage 7C row contains its own exact synchronous control result.

## Direct dependency boundary

The Stage 7C Rust crate lives at:

~~~text
stage7c/p2panda/
~~~

Starlings Core itself still has:

~~~text
no Rust dependency
no P2Panda dependency
no Iroh dependency
no GLib dependency
~~~

The Rust crate's build script invokes Zig to build only the Stage 7C policy ABI
as a static library.

Thus:

~~~text
Starlings Core
     |
     +-- optional Stage 7C experimental adapter
             |
             +-- Rust
             +-- P2Panda
             +-- Iroh transitively
~~~

## Distributed runtime

The initial canonical harness spawns N native P2Panda nodes in one Rust
process.

Every node has:

~~~text
independent local Starlings state
independent local policy tick
independent P2Panda Node
independent topic publisher/subscriber
independent P2Panda local store
~~~

All nodes subscribe to one experiment topic.

This intentionally exercises:

~~~text
asynchronous task scheduling
real signed P2Panda operations
eventually consistent synchronization
local-first operation persistence
P2Panda processing pipeline
at-least-once delivery semantics
real sync sessions and byte accounting
~~~

while keeping deployment easy enough for a canonical first transfer test.

## Logical topology versus P2Panda dissemination

P2Panda's topic synchronization is not the Starlings control law.

Stage 7C therefore preserves the Stage 5/7 topology in the application
envelope.

A published envelope contains:

~~~text
run nonce
sender
local sequence
local logical round
logical recipients
selected facts
~~~

Every P2Panda node may physically receive the operation.

Only a node listed in logical recipients applies the fact update.

Thus measurements are separated into two layers.

### Starlings logical metrics

~~~text
actions
logical messages
communication units
useful deliveries
duplicate deliveries
collector completion
local policy rounds
~~~

### P2Panda physical/runtime metrics

~~~text
local processed operations
remote processed operations
duplicate envelopes observed
sync sessions
sync sent bytes
sync received bytes
sync errors
~~~

This prevents P2Panda's own dissemination strategy from being silently counted
as pi_theta.

## At-least-once handling

P2Panda 0.7 topic streams provide at-least-once application delivery.

Stage 7C envelopes therefore include:

~~~text
(run_nonce, sender, sequence)
~~~

as a deterministic idempotency key.

Every node tracks already processed envelope keys.

Repeated application delivery increments:

~~~text
duplicate_envelopes
~~~

but does not mutate Starlings knowledge twice.

This is part of the transfer test rather than being hidden by the adapter.

## Asynchronous local rounds

There is no synchronized global Stage 7C round.

Every node advances its own local round on a Tokio interval.

On each local policy tick:

~~~text
observe current local state
       |
       v
exact Zig pi_theta
       |
       v
selected fact set
       |
       v
P2Panda persistent operation
~~~

Incoming operations can be processed between any two local policy ticks.

This is the main semantic change from Stage 7B and the reason Stage 7C is a
meaningful transfer test.

## Completion

Collector operator 0 retains the Stage 5/7 target:

~~~text
collector knows all F facts
~~~

When collector completion occurs, the harness allows a short drain interval so
already-published operations can finish application processing before all node
tasks stop.

This keeps useful/duplicate delivery accounting less sensitive to task race
ordering at the exact completion instant.

## Default smoke world

~~~text
profile: theta51
N=8
F=32
G=ring
R=2
B=2
seed=0

local tick: 20 ms
discovery warm-up: 1000 ms
post-success drain: 500 ms
max local ticks: 1024
synchronous horizon: 4096
~~~

Run:

~~~sh
cd stage7c/p2panda

cargo test

cargo run --release -- \
  --profile theta51 \
  --nodes 8 \
  --facts 32 \
  --topology ring \
  --redundancy 2 \
  --bandwidth 2 \
  --seed 0
~~~

The build requires Rust 1.96 or newer because P2Panda 0.7.0 declares that
minimum toolchain.

## Output schema

One TSV row contains:

~~~text
profile
theta n/e/r/u
N/F/G/R/B/seed

synchronous:
  success
  rounds
  logical communication

distributed:
  success
  elapsed milliseconds
  collector initial/final facts
  max local round
  actions
  logical messages
  logical communication
  useful deliveries
  duplicate deliveries

P2Panda:
  local processed operations
  remote processed operations
  duplicate envelopes
  sync sessions
  sync sent bytes
  sync received bytes
  sync errors

policy FFI errors
~~~

## What Stage 7C can establish

A successful first transfer result supports:

> A compact local coordination policy selected entirely in a synchronous
> deterministic simulator remains functional when the same policy is executed
> independently over a real asynchronous local-first causal replication
> substrate.

It does not yet establish:

~~~text
robustness to real IP-layer partitions
WAN behavior
netem loss/latency robustness
process crash/restart robustness
multi-machine behavior
RF/off-grid behavior
~~~

Those require later Stage 7C subexperiments.

## Next Stage 7C subtest

After the local multi-node transfer is clean, the same Rust harness should be
split into one node per process without changing the policy ABI or envelope.

Then network namespaces / netem can impose actual:

~~~text
partition
reconnect
latency
loss
reordering
rate limits
process restart
~~~

That becomes the canonical disruption-transfer test.

The architectural invariant remains:

> Starlings owns decisions. P2Panda owns durable distributed state and
> synchronization. Iroh owns the current network transport.
