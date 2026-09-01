#!/usr/bin/env python3
"""Zero-neural deterministic control operator for condition C."""

from __future__ import annotations

import json
import pathlib
import sys

PROJECT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PROJECT))

from starlings_harbor.wire import (
    b64decode_text,
    b64encode_text,
    claim_text,
    parse_request,
    response,
)


COMMANDS = (
    "pwd; printf '\\n--- files ---\\n'; find . -maxdepth 2 -type f | sort | head -200",
    (
        "if [ -f pyproject.toml ]; then "
        "(python -m pytest -q || pytest -q || true); "
        "elif [ -f package.json ]; then "
        "(npm test -- --runInBand || npm test || true); "
        "elif [ -f Cargo.toml ]; then cargo test || true; "
        "elif [ -f build.zig ]; then zig build test || true; "
        "else printf 'no recognized deterministic test entrypoint\\n'; fi"
    ),
)


def main() -> int:
    request = parse_request(sys.stdin.read())
    if len(request.variables) < 2 or len(request.provides) < 2:
        raise RuntimeError("deterministic planner received an incomplete request")

    history = json.loads(b64decode_text(request.variables[1][2]))
    if not isinstance(history, list):
        raise RuntimeError("history must be a JSON list")

    if len(history) < len(COMMANDS):
        target = request.provides[0]
        value = COMMANDS[len(history)]
    else:
        target = request.provides[1]
        value = "Deterministic Starlings completed its bounded inspection."

    sys.stdout.write(
        response(
            request.operator_id,
            [claim_text(target, request.operator_id, b64encode_text(value))],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
