# F1a deterministic fault-matrix evidence

F1a evaluates the frozen Stage 7C asynchronous coordination policies under a
canonical deterministic contested-environment matrix.

## Canonical result

~~~text
rows: 432
successes: 397
non-convergent: 35

byte_identical_replay: yes
envelope_accounting_failures: 0
missing_accounting_failures: 0
unattributed_missing: 0
violations: 0

dataset bytes: 68973
SHA-256:
c9d6b93937467ebf363ee14a02b2028ba0993d50a282770c547eaa3d35ed3ae5
~~~

The dataset is generated as `trials/f1a-fault-matrix.tsv` in the experiments
repository and is intentionally not committed. This document freezes its
identity and result summary.

## Frozen axes

- profiles: `theta37`, `theta51`, `theta93`, `round_robin`, `seeded`,
  `novel_first`
- topologies: ring, grid
- world/schedule seeds: 0, 1, 2
- N=8, F=32, R=2, B=2, max virtual ticks=4096
- 12 fault worlds: no-fault, two loss levels, duplication, latency/jitter,
  forced reordering, partition/reconnect, crash/restart with persistent and
  reset knowledge, stale view, bounded queue, and a combined contested world

## Fault-tolerance summary

| Profile | Successes | Canonical worlds | Terminal missing | Communication units |
| --- | ---: | ---: | ---: | ---: |
| novel_first | 66 | 72 | 22 | 181035 |
| round_robin | 67 | 72 | 18 | 176508 |
| seeded | 66 | 72 | 17 | 238524 |
| theta37 | 66 | 72 | 19 | 181687 |
| theta51 | 66 | 72 | 21 | 180593 |
| theta93 | 66 | 72 | 21 | 116470 |

## Interpretation

F1a is a PASS because the scientific gate is deterministic replay and complete
causal accounting, not universal convergence. Every one of the 35
non-convergent worlds has its missing facts attributed to one of the frozen
terminal causes:

- `never_transmitted`
- `delivery_faulted`
- `crashed_before_merge`
- `pending_at_censor`

No canonical world contains an unattributed missing fact, and no protocol or
accounting identity is violated.

The deterministic substrate remains the authoritative measurement layer for
F1b, F2, F3, and F4.
