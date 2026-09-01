"""Persistent Python-side client for the real Zig Starlings bridge."""

from __future__ import annotations

import asyncio
import base64
import pathlib
import sys
from dataclasses import dataclass


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
BRIDGE_BINARY = REPO_ROOT / "zig-out" / "bin" / "starlings-harbor-bridge"

_build_lock = asyncio.Lock()


async def ensure_bridge_built() -> pathlib.Path:
    if BRIDGE_BINARY.is_file():
        return BRIDGE_BINARY

    async with _build_lock:
        if BRIDGE_BINARY.is_file():
            return BRIDGE_BINARY
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "ziglang",
            "build",
            "-Doptimize=ReleaseSafe",
            cwd=REPO_ROOT,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        output, _ = await process.communicate()
        if process.returncode != 0:
            raise RuntimeError(
                "failed to build Starlings Harbor bridge:\n"
                + output.decode("utf-8", errors="replace")
            )
        if not BRIDGE_BINARY.is_file():
            raise RuntimeError("Zig build succeeded but bridge binary is missing")
        return BRIDGE_BINARY


@dataclass(frozen=True)
class BridgeDecision:
    kind: str
    value: str


class StarlingsBridge:
    def __init__(self, process: asyncio.subprocess.Process):
        self.process = process

    @classmethod
    async def start(cls, pack: str) -> "StarlingsBridge":
        binary = await ensure_bridge_built()
        pack_path = PROJECT_ROOT / "packs" / pack
        process = await asyncio.create_subprocess_exec(
            str(binary),
            str(pack_path),
            cwd=REPO_ROOT,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        return cls(process)

    async def _exchange(self, verb: str, value: str) -> BridgeDecision:
        if self.process.stdin is None or self.process.stdout is None:
            raise RuntimeError("Starlings bridge pipes are unavailable")
        payload = base64.b64encode(value.encode("utf-8")).decode("ascii")
        self.process.stdin.write(f"{verb} {payload}\n".encode("ascii"))
        await self.process.stdin.drain()

        line = await self.process.stdout.readline()
        if not line:
            detail = ""
            if self.process.stderr is not None:
                detail = (await self.process.stderr.read()).decode(
                    "utf-8", errors="replace"
                )
            raise RuntimeError(
                f"Starlings bridge exited unexpectedly: {detail[:4000]}"
            )

        decoded = line.decode("utf-8").rstrip("\r\n")
        kind, _, encoded = decoded.partition(" ")
        if kind == "IDLE":
            return BridgeDecision("idle", "")
        if kind == "ERROR":
            return BridgeDecision("error", encoded)
        if kind not in {"ACTION", "FINAL"} or not encoded:
            raise RuntimeError(f"invalid Starlings bridge response: {decoded!r}")
        value = base64.b64decode(encoded.encode("ascii"), validate=True).decode("utf-8")
        return BridgeDecision(kind.lower(), value)

    async def start_task(self, task: str) -> BridgeDecision:
        return await self._exchange("START", task)

    async def update_history(self, history: str) -> BridgeDecision:
        return await self._exchange("HISTORY", history)

    async def close(self) -> None:
        if self.process.returncode is not None:
            return
        if self.process.stdin is not None:
            self.process.stdin.write(b"QUIT\n")
            await self.process.stdin.drain()
            self.process.stdin.close()
        try:
            await asyncio.wait_for(self.process.wait(), timeout=5)
        except TimeoutError:
            self.process.kill()
            await self.process.wait()
