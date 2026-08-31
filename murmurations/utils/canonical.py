"""Restricted canonical encoding and BLAKE3 identities.

The protocol intentionally avoids floats in identity-bearing records. Confidence
is represented as integer permille. This keeps canonicalization small and
portable while the Zig runtime remains the authority for production encodings.
"""

from __future__ import annotations

import json
from typing import Any

from blake3 import blake3

_DOMAIN = b"STARLINGS:MURMURATION:FRAME:1\x00"


def _normalize(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, bytes):
        return {"$bytes": value.hex()}
    if isinstance(value, (list, tuple)):
        return [_normalize(item) for item in value]
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise TypeError("canonical maps require string keys")
        return {key: _normalize(value[key]) for key in sorted(value)}
    if isinstance(value, float):
        raise TypeError("identity-bearing records use integers, not floats")
    raise TypeError(f"unsupported canonical value: {type(value)!r}")


def canonical_bytes(value: Any) -> bytes:
    normalized = _normalize(value)
    return json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def canonical_id(value: Any, *, domain: bytes = _DOMAIN) -> str:
    return "b3:" + blake3(domain + canonical_bytes(value)).hexdigest()
