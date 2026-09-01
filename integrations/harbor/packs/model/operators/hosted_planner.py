#!/usr/bin/env python3
"""Starlings external operator backed by Harbor's selected hosted model."""

from __future__ import annotations

import os
import pathlib
import sys

PROJECT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PROJECT))

from starlings_harbor.inference import decide
from starlings_harbor.wire import (
    b64decode_text,
    b64encode_text,
    claim_text,
    parse_request,
    response,
)


def main() -> int:
    request = parse_request(sys.stdin.read())
    if len(request.variables) < 2 or len(request.provides) < 2:
        raise RuntimeError("hosted planner received an incomplete Starlings request")

    task = b64decode_text(request.variables[0][2])
    history = b64decode_text(request.variables[1][2])
    model = (
        os.environ.get("STARLINGS_HARBOR_MODEL")
        or os.environ.get("HARBOR_ACP_REQUESTED_MODEL")
    )
    if not model:
        raise RuntimeError("Starlings hosted planner has no selected model")

    decision = decide(task, history, model)
    target = request.provides[0] if decision.kind == "shell" else request.provides[1]
    encoded = b64encode_text(decision.value)
    sys.stdout.write(
        response(
            request.operator_id,
            [claim_text(target, request.operator_id, encoded)],
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
