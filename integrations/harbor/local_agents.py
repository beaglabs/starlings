"""Normal Harbor BaseAgent adapters for Molab + Daytona CPU evaluation."""

from __future__ import annotations

import asyncio
import json
import os
import shlex
from pathlib import Path
from typing import Any

from harbor.agents.base import BaseAgent
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext

from .starlings_harbor.bridge import StarlingsBridge, ensure_bridge_built
from .starlings_harbor.inference import decide, history_text


_MCP_REMOTE = "/tmp/starlings-harbor-mcp.py"


def _combine_output(stdout: str | None, stderr: str | None) -> str:
    pieces = []
    if stdout:
        pieces.append(stdout)
    if stderr:
        pieces.append("[stderr]\n" + stderr)
    text = "\n".join(pieces)
    if len(text) > 12000:
        text = text[-12000:]
        return "[output prefix truncated]\n" + text
    return text


def _read_usage(path: Path) -> dict[str, float | int]:
    totals: dict[str, float | int] = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_tokens": 0,
        "cost_usd": 0.0,
    }
    if not path.exists():
        return totals
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        for key in ("input_tokens", "output_tokens", "cache_tokens"):
            totals[key] = int(totals[key]) + int(item.get(key, 0) or 0)
        totals["cost_usd"] = float(totals["cost_usd"]) + float(
            item.get("cost_usd", 0.0) or 0.0
        )
    return totals


class _CommonAgent(BaseAgent):
    condition = "unknown"

    def __init__(
        self,
        *args: Any,
        max_turns: int = 50,
        command_timeout_sec: float = 180.0,
        **kwargs: Any,
    ) -> None:
        super().__init__(*args, **kwargs)
        self.max_turns = int(max_turns)
        self.command_timeout_sec = float(command_timeout_sec)
        self._usage_log = self.logs_dir / "model-usage.jsonl"

    def version(self) -> str:
        return "0.2.0"

    async def setup(self, environment: BaseEnvironment) -> None:
        if self.condition in {"starlings", "deterministic"}:
            # Build once on the Molab host, not in every Daytona task sandbox.
            await ensure_bridge_built()

        http_servers = [
            server
            for server in self.mcp_servers
            if server.transport == "streamable-http" and server.url
        ]
        if not http_servers:
            return

        helper = Path(__file__).with_name("mcp_bridge.py")
        await environment.upload_file(helper, _MCP_REMOTE)
        probe = await environment.exec(
            command=(
                "python3 -c 'import mcp' >/dev/null 2>&1 || "
                "python3 -m pip install --user --no-cache-dir 'mcp==1.25.0'"
            ),
            timeout_sec=180,
        )
        if probe.return_code != 0:
            raise RuntimeError(
                "failed to install MCP client in task sandbox: "
                + _combine_output(probe.stdout, probe.stderr)
            )

    def _augment_instruction(self, instruction: str) -> str:
        servers = [
            server
            for server in self.mcp_servers
            if server.transport == "streamable-http" and server.url
        ]
        if not servers:
            return instruction

        lines = [
            instruction,
            "",
            "MCP TOOLS:",
            "The following MCP servers are reachable from inside the task environment.",
            "Use the terminal helper below to discover and invoke their tools.",
        ]
        for server in servers:
            url = shlex.quote(server.url or "")
            lines.extend(
                [
                    f"- {server.name}: {server.url}",
                    f"  list: python3 {_MCP_REMOTE} list {url}",
                    (
                        f"  call: python3 {_MCP_REMOTE} call {url} "
                        "TOOL_NAME 'JSON_ARGUMENT_OBJECT'"
                    ),
                ]
            )
        return "\n".join(lines)

    async def _shell(
        self,
        environment: BaseEnvironment,
        command: str,
    ) -> dict[str, Any]:
        result = await environment.exec(
            command=command,
            timeout_sec=self.command_timeout_sec,
        )
        return {
            "command": command,
            "output": _combine_output(result.stdout, result.stderr),
            "exit_code": result.return_code,
        }

    def _finish_context(
        self,
        context: AgentContext,
        *,
        turns: int,
        final_answer: str,
    ) -> None:
        usage = _read_usage(self._usage_log)
        context.n_input_tokens = int(usage["input_tokens"])
        context.n_output_tokens = int(usage["output_tokens"])
        context.n_cache_tokens = int(usage["cache_tokens"])
        context.cost_usd = float(usage["cost_usd"])
        context.metadata = {
            "starlings_condition": self.condition,
            "turns": turns,
            "model": self.model_name,
            "final_answer": final_answer,
        }
        (self.logs_dir / "final-answer.txt").write_text(
            final_answer + "\n", encoding="utf-8"
        )


class BaselineAgent(_CommonAgent):
    """Condition A: conventional loop around the frozen/hosted model."""

    condition = "baseline"

    @staticmethod
    def name() -> str:
        return "starlings-baseline"

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if not self.model_name:
            raise ValueError("BaselineAgent requires model_name")

        task = self._augment_instruction(instruction)
        history: list[dict[str, Any]] = []
        final = "Turn budget exhausted."
        turns = 0
        for turns in range(1, self.max_turns + 1):
            decision = await asyncio.to_thread(
                decide,
                task,
                history_text(history),
                self.model_name,
                self._usage_log,
            )
            if decision.kind == "final":
                final = decision.value
                break
            history.append(await self._shell(environment, decision.value))
        self._finish_context(context, turns=turns, final_answer=final)


class StarlingsAgent(_CommonAgent):
    """Condition B: the same model routed through the real Zig Starlings runtime."""

    condition = "starlings"

    @staticmethod
    def name() -> str:
        return "starlings"

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        if not self.model_name:
            raise ValueError("StarlingsAgent requires model_name")

        task = self._augment_instruction(instruction)
        history: list[dict[str, Any]] = []
        bridge = await StarlingsBridge.start(
            "model",
            env={
                "STARLINGS_HARBOR_MODEL": self.model_name,
                "STARLINGS_HARBOR_USAGE_LOG": str(self._usage_log),
            },
        )
        final = "Starlings quiesced without a final answer."
        turns = 0
        try:
            decision = await bridge.start_task(task)
            for turns in range(1, self.max_turns + 1):
                if decision.kind == "final":
                    final = decision.value
                    break
                if decision.kind == "error":
                    raise RuntimeError("Starlings bridge: " + decision.value)
                if decision.kind != "action":
                    break

                history.append(await self._shell(environment, decision.value))
                decision = await bridge.update_history(history_text(history))
            else:
                final = "Turn budget exhausted."
        finally:
            await bridge.close()

        self._finish_context(context, turns=turns, final_answer=final)


class DeterministicStarlingsAgent(_CommonAgent):
    """Condition C: real Starlings runtime with no model dependency."""

    condition = "deterministic"

    @staticmethod
    def name() -> str:
        return "starlings-deterministic"

    async def run(
        self,
        instruction: str,
        environment: BaseEnvironment,
        context: AgentContext,
    ) -> None:
        task = self._augment_instruction(instruction)
        history: list[dict[str, Any]] = []
        bridge = await StarlingsBridge.start("deterministic")
        final = "Starlings quiesced without a final answer."
        turns = 0
        try:
            decision = await bridge.start_task(task)
            for turns in range(1, self.max_turns + 1):
                if decision.kind == "final":
                    final = decision.value
                    break
                if decision.kind == "error":
                    raise RuntimeError("Starlings bridge: " + decision.value)
                if decision.kind != "action":
                    break
                history.append(await self._shell(environment, decision.value))
                decision = await bridge.update_history(history_text(history))
            else:
                final = "Turn budget exhausted."
        finally:
            await bridge.close()

        self._finish_context(context, turns=turns, final_answer=final)
