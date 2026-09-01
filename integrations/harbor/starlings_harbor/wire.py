"""Helpers for the canonical STARLINGS/1 external-operator wire format."""

from __future__ import annotations

import base64
from dataclasses import dataclass


@dataclass(frozen=True)
class WireRequest:
    operator_id: int
    variables: list[tuple[int, int, str]]
    provides: list[int]


def b64encode_text(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def b64decode_text(value: str) -> str:
    return base64.b64decode(value.encode("ascii"), validate=True).decode("utf-8")


def parse_request(text: str) -> WireRequest:
    lines = [line for line in text.splitlines() if line]
    if not lines or lines[0] != "STARLINGS/1 REQUEST" or lines[-1] != "END":
        raise ValueError("invalid STARLINGS/1 request")

    operator_id: int | None = None
    variables: list[tuple[int, int, str]] = []
    provides: list[int] = []

    for line in lines[1:-1]:
        if line.startswith("operator="):
            operator_id = int(line.split("=", 1)[1])
        elif line.startswith("var="):
            var_id, status, encoded = line.split("=", 1)[1].split(",", 2)
            if not encoded.startswith("t:"):
                raise ValueError("Harbor pack variables must be text values")
            variables.append((int(var_id), int(status), encoded[2:]))
        elif line.startswith("provide_var="):
            provides.append(int(line.split("=", 1)[1]))

    if operator_id is None:
        raise ValueError("request is missing operator id")
    return WireRequest(operator_id, variables, provides)


def claim_text(variable_id: int, operator_id: int, encoded_text: str) -> str:
    if any(ch in encoded_text for ch in "\r\n,"):
        raise ValueError("wire text is not canonical-safe")
    return f"claim={variable_id},3,1000,{operator_id},t:{encoded_text}"


def response(operator_id: int, claims: list[str]) -> str:
    return (
        "STARLINGS/1 RESPONSE\n"
        + f"operator={operator_id}\n"
        + "".join(claim + "\n" for claim in claims)
        + "END\n"
    )
