"""Minimal Starlings wire-v1 helper for Python operators.

Usage:

    from starlings_operator import serve, derived

    def operator(ctx):
        value = ctx["variables"][1]["value"]
        return {
            "claims": [derived(2, value + 1, source_operator=10)]
        }

    if __name__ == "__main__":
        serve(operator)
"""

from __future__ import annotations

import struct
import sys
from typing import Any, Callable, Dict, Iterable, List


STATUS = {
    "unknown": 0,
    "observed": 1,
    "estimated": 2,
    "derived": 3,
    "not_visible": 4,
    "unavailable": 5,
    "blocked": 6,
    "conflicting": 7,
}


def _decode_value(encoded: str) -> Any:
    if encoded == "n":
        return None
    kind, payload = encoded.split(":", 1)
    if kind == "i":
        return int(payload)
    if kind == "f":
        return struct.unpack(">d", bytes.fromhex(payload))[0]
    if kind == "b":
        return payload == "1"
    if kind == "t":
        return payload
    if kind == "a":
        return {"artifact_ref": payload}
    raise ValueError(f"unknown wire value kind: {kind}")


def _encode_value(value: Any) -> str:
    if value is None:
        return "n"
    if isinstance(value, bool):
        return "b:1" if value else "b:0"
    if isinstance(value, int):
        return f"i:{value}"
    if isinstance(value, float):
        return "f:" + struct.pack(">d", value).hex()
    if isinstance(value, str):
        if any(c in value for c in "\r\n,"):
            raise ValueError("wire-v1 text cannot contain comma/newline")
        return "t:" + value
    if isinstance(value, dict) and "artifact_ref" in value:
        return "a:" + value["artifact_ref"]
    raise TypeError(f"unsupported Starlings wire value: {type(value)!r}")


def decode_request(text: str) -> Dict[str, Any]:
    lines = [line for line in text.splitlines() if line]
    if not lines or lines[0] != "STARLINGS/1 REQUEST":
        raise ValueError("invalid Starlings wire header")

    ctx: Dict[str, Any] = {"variables": {}}
    for line in lines[1:]:
        if line == "END":
            break
        if line.startswith("operator="):
            ctx["operator"] = int(line.split("=", 1)[1])
        elif line.startswith("round="):
            ctx["round"] = int(line.split("=", 1)[1])
        elif line.startswith("var="):
            variable, status, value = line[4:].split(",", 2)
            ctx["variables"][int(variable)] = {
                "status": int(status),
                "value": _decode_value(value),
            }
        else:
            raise ValueError(f"unknown Starlings wire record: {line}")
    return ctx


def claim(
    variable: int,
    value: Any,
    *,
    status: str,
    source_operator: int,
    confidence: int = 1000,
) -> Dict[str, Any]:
    return {
        "variable": variable,
        "status": STATUS[status],
        "confidence": confidence,
        "source_operator": source_operator,
        "value": value,
    }


def observed(variable: int, value: Any, *, source_operator: int, confidence: int = 1000):
    return claim(variable, value, status="observed", source_operator=source_operator, confidence=confidence)


def estimated(variable: int, value: Any, *, source_operator: int, confidence: int = 1000):
    return claim(variable, value, status="estimated", source_operator=source_operator, confidence=confidence)


def derived(variable: int, value: Any, *, source_operator: int, confidence: int = 1000):
    return claim(variable, value, status="derived", source_operator=source_operator, confidence=confidence)


def blocked(variable: int, *, source_operator: int):
    return claim(variable, None, status="blocked", source_operator=source_operator)


def encode_response(operator_id: int, output: Dict[str, Any]) -> str:
    lines: List[str] = ["STARLINGS/1 RESPONSE", f"operator={operator_id}"]
    for item in output.get("claims", []):
        lines.append(
            "claim="
            + ",".join(
                [
                    str(item["variable"]),
                    str(item["status"]),
                    str(item.get("confidence", 1000)),
                    str(item["source_operator"]),
                    _encode_value(item.get("value")),
                ]
            )
        )
    for item in output.get("invariants", []):
        lines.append(
            f'invariant={item["invariant"]},{item["status"]},{item["source_operator"]}'
        )
    for item in output.get("actions", []):
        name = item["name"]
        payload = item.get("payload", "")
        if any(c in name + payload for c in "\r\n,"):
            raise ValueError("wire-v1 actions cannot contain comma/newline")
        lines.append(
            f'action={name},{1 if item.get("requires_approval") else 0},{payload}'
        )
    lines.append("END")
    return "\n".join(lines) + "\n"


def serve(operator: Callable[[Dict[str, Any]], Dict[str, Any]]) -> None:
    request = decode_request(sys.stdin.read())
    operator_id = int(request["operator"])
    response = operator(request)
    sys.stdout.write(encode_response(operator_id, response))
    sys.stdout.flush()
