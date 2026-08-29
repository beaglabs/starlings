# F1c zquic transport evidence

F1c evaluates a thin, pure-Zig real transport candidate after the F1b
P2Panda path exposed recurring background-runtime panics during local
validation.

The candidate deliberately leaves all Starlings semantics above the transport
boundary:

~~~text
Starlings semantics
  -> minimal length-prefixed envelope
  -> zquic raw application stream
  -> QUIC / TLS 1.3 / loss recovery / congestion control
  -> UDP loopback
~~~

No discovery, mDNS, DHT, libp2p, database, replication runtime, HTTP,
WebSocket, Rust runtime, or FFI participates in F1c.

## Frozen dependency

~~~text
repository:   zigstack/zquic
tag:          v1.7.48
commit:       4bd041ac95425fb0aa229b74c9d3316c74aaf829
package hash: zquic-1.7.0-2zRc1PSAFgDCESpm-vZsUr4O02HM0dpzmVJSx5WXW6ES
minimum Zig:  0.16.0
~~~

The zquic package itself pins `zig-varint` v0.1.0.

## Preserved Starlings semantics

F1c keeps the frozen Stage 7A policy and Stage 7C/F1a asynchronous schedule:

~~~text
schedule_seed = world seed
clock_jitter = 3
~~~

Every logical recipient attempt remains identified by:

~~~text
(sender, sequence, recipient)
~~~

and the candidate transport is not permitted to invent retries at the
Starlings accounting layer. QUIC retransmissions remain transport-internal.

The canonical crash target is collector node 0, matching F1a.

## Canonical result — 2026-08-29

The authoritative local verifier completed on macOS with Zig 0.16.0.

~~~text
rows: 42
dataset bytes: 8007
SHA-256:
6ef0b88e5c06c1ceb3ce41ec08e1fcec89a08743e7e2440e5d48a097b3e66ddb

fault_free_rows:       24
fault_free_successes:  24/24

determinism_audit_rows: 12
determinism_K:           3

contested_rows: 6

envelope_accounting_failures:      0
missing_accounting_failures:       0
communication_accounting_failures: 0
protocol_violations:                0
send_failures:                      0
malformed_frames:                   0
unattributed_missing:               0
pending_at_censor:                  0
transport_panics:                   0
backpressure_events:                0

udp_datagrams: 37396
~~~

The generated dataset is:

~~~text
trials/f1c-zquic-wired.tsv
~~~

in `beaglabs/starling-experiments` and remains intentionally uncommitted.
This document freezes its identity and result summary.

## Determinism audit

All four fixed worlds were full-row stable across K=3 reruns:

~~~text
novel_first / grid / seed 2
  signature:
  6d24eee242cc7dbc
  stable=yes

theta37 / ring / seed 0
  signature:
  45f9f003bc89eab4
  stable=yes

theta51 / grid / seed 1
  signature:
  9926f2289bf713c8
  stable=yes

theta93 / ring / seed 2
  signature:
  608d12243989469e
  stable=yes
~~~

The full result row was compared, not only the signature field, so the audit
covers the deterministic schedule hash and the measured QUIC counters emitted
by the experiment.

## Accounting

Every canonical row satisfies:

~~~text
transport_attempts
  = delivered
  + partitioned
  + crashed
  + pending

communication_units
  = useful
  + duplicate
~~~

Every terminal missing collector fact is attributable to the frozen F1a cause
vocabulary:

- `never_transmitted`
- `delivery_faulted`
- `crashed_before_merge`
- `pending_at_censor`
- `unattributed`

The canonical F1c result contains zero unattributed and zero pending-at-censor
missing facts.

## Interpretation

F1c is a **PASS**.

The pinned zquic candidate:

- converges in all 24 fault-free canonical worlds;
- preserves exact logical attempt and communication accounting;
- produces no malformed frames, send failures, protocol violations, or
  background transport panics;
- remains fully accounted under the six partition/crash contested worlds;
- reproduces all four fixed audit worlds byte-for-byte at the full result-row
  level across K=3 reruns.

The deterministic Zig substrate remains authoritative. zquic is recorded as a
validated real-transport candidate beneath the Starlings protocol boundary,
not as a replacement for the deterministic measurement substrate.
