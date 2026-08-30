# Durable Artifact Storage — Phase 3C

Phase 3C makes Phase 3 artifact references resolve to durable, content-addressed
bytes inside the run store.

Phase 3A made artifact emission canonical and replayable. Phase 3B made external
operators real supervised processes. Phase 3C closes the remaining durability
gap between an `artifact_emitted` event and the bytes named by that event.

## Run layout

Each durable run now owns:

```text
.starlings/runs/<run-id>/
├── configuration.bin
├── events.ndjson
└── artifacts/
    └── <64-hex-content-id>.artifact
```

Artifact files are scoped to a run. This keeps run deletion, copying, archival,
and forensic inspection self-contained.

## Artifact identity

Artifact identity remains the Phase 3A canonical identity:

```text
BLAKE3(
    artifact_version
    || media_type_length
    || media_type
    || payload_length
    || payload_bytes
)
```

Changing either the media type or any payload byte changes the artifact ID.

The artifact file stores:

- artifact storage magic/version;
- media type;
- declared byte length;
- payload bytes.

The content ID itself is encoded in the filename and is recomputed on load.

## Persist-first / emit-second invariant

A durable operator should emit artifacts in this order:

```text
bytes
  |
  v
RunWriter.putArtifact(media_type, bytes)
  |
  +-- write artifact envelope
  +-- fsync artifact file
  +-- return ArtifactRef
  |
  v
OperatorOutput.addArtifact(ref)
  |
  v
Runner artifact verifier
  |
  v
artifact_emitted event
```

When a Runner has an artifact verifier configured, an artifact reference must
resolve to durable bytes with matching:

- content ID;
- media type;
- byte length.

A failed verification is treated as an operator output validation failure and
no `artifact_emitted` event is appended.

In-memory runs may still operate without a verifier. The durable guarantee
applies when the run store's verifier is attached.

## Deduplication

A repeated `putArtifact()` for the same media type and bytes produces the same
content ID.

The store creates artifact files exclusively. If the file already exists, the
existing artifact is loaded and verified rather than overwritten.

This prevents a duplicate write from truncating a previously durable artifact.

## Corruption detection

Every load:

1. validates the artifact envelope;
2. validates the declared byte length;
3. recomputes the canonical artifact content ID;
4. compares it with the requested filename/content ID.

A modified payload therefore fails with an artifact identity error instead of
silently returning corrupted data.

## Restart and replay

After the live run closes:

1. configuration is loaded;
2. the event log is loaded;
3. the artifact store is reopened for the same run ID;
4. an `artifact_emitted` ID can be loaded back into its full
   `ArtifactRef + bytes`;
5. Runner replay reconstructs the same canonical event/state history without
   re-executing operators.

Artifact bytes are not duplicated into the event log. Replay remains compact;
the event stream contains identity/size while the artifact store contains the
durable payload and media metadata.

## Phase 3C acceptance coverage

The branch covers:

- store / load round-trip;
- duplicate content deduplication;
- media type and size verification;
- corruption detection by re-hash;
- Runner fail-closed behavior for unpersisted artifact refs;
- durable operator execution using `RunWriter.putArtifact`;
- close / reopen / retrieve artifact bytes by emitted content ID;
- normal event-log replay preserving the artifact emission.

## Scope boundary

Phase 3C does not yet bind pack declarations to executable native/Python/
subprocess implementations.

The next slice, Phase 3D, should provide the actual pack execution entry point
and heterogeneous implementation binding so a declared pack can be run through
the complete Phase 3 substrate end to end.
