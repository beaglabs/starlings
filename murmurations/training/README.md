# Training

## 1. Build the tokenizer

The 500M configuration assumes a **32,768-token vocabulary**. Train it on the
same mixture of code, language, Starlings protocol traces, and canonical action
records used for pretraining:

```sh
python -m murmurations.training.tokenizer \\
  --input data/code.jsonl data/protocol.jsonl data/text.txt \\
  --output murmurations/models/murmuration-500m-v0/tokenizer \\
  --vocab-size 32768
```

## 2. Prepare trajectory JSONL

Each row supervises language generation and a protocol decision at the context
boundary:

```json
{
  "context": "repo evidence ... b3:0123... symbol execution.Runner.step",
  "language_target": "The invariant registry is empty.",
  "operation": "QUERY",
  "argument": {
    "kind": "SYMBOL",
    "text": "execution.Runner.step",
    "parents": ["b3:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"],
    "confidence_permille": 910
  }
}
```

`argument.text` and parent IDs must occur verbatim in the context. They become
pointer labels, not generated identifiers.

## 3. Smoke test first

Point `configs/smoke.yaml` at tiny train/eval JSONL files and the tokenizer,
then run:

```sh
accelerate launch -m murmurations.training.train \\
  --config murmurations/training/configs/smoke.yaml
```

## 4. Train the ~500M baseline

```sh
accelerate config
accelerate launch -m murmurations.training.train \\
  --config murmurations/training/configs/murmuration-500m-v0.yaml
```

The recipe is compatible with Accelerate's DDP/FSDP launch configuration. The
model itself does not depend on Transformers model classes.

### Objective

The total objective is a weighted sum of:

- causal language/code cross entropy;
- operation classification;
- argument-kind classification;
- argument start/end pointer loss;
- direct-parent pointer loss and parent-count loss;
- confidence calibration.

Successful environment episodes should later add outcome/credit objectives from
compiler tests, hidden tests, replay validity, and accepted/retracted/challenged
Merkle-DAG contributions.

### 500M geometry

The v0 baseline uses:

- vocabulary: 32,768
- width: 1,024
- layers: 28
- attention heads: 16
- SwiGLU hidden width: 4,096
- tied language projection

This is approximately 503M parameters before tiny protocol-head differences.
