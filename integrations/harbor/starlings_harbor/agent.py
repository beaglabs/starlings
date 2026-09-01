"""One ACP implementation exposing the controlled A/B/C experiment."""

from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass, field
from typing import Any, Literal
from uuid import uuid4

from acp import Agent, InitializeResponse, NewSessionResponse, PromptResponse
from acp.interfaces import Client
from acp.schema import (
    AgentMessageChunk,
    AudioContentBlock,
    ClientCapabilities,
    EmbeddedResourceContentBlock,
    HttpMcpServer,
    ImageContentBlock,
    Implementation,
    McpServerStdio,
    ResourceContentBlock,
    SessionConfigOptionSelect,
    SessionConfigSelectOption,
    SetSessionConfigOptionResponse,
    SseMcpServer,
    TextContentBlock,
)

from .bridge import BridgeDecision, StarlingsBridge
from .inference import decide, history_text


Mode = Literal["baseline", "starlings", "deterministic"]


@dataclass
class Session:
    cwd: str
    model: str | None
    history: list[dict[str, Any]] = field(default_factory=list)
    bridge: StarlingsBridge | None = None


def _prompt_text(blocks: list[Any]) -> str:
    chunks: list[str] = []
    for block in blocks:
        if isinstance(block, dict):
            text = block.get("text")
        else:
            text = getattr(block, "text", None)
        if isinstance(text, str):
            chunks.append(text)
    return "\n".join(chunks)


class HarborExperimentAgent(Agent):
    def __init__(self, mode: Mode):
        self.mode = mode
        self._conn: Client
        self._sessions: dict[str, Session] = {}
        self.max_turns = int(os.environ.get("STARLINGS_HARBOR_MAX_TURNS", "50"))

    def on_connect(self, conn: Client) -> None:
        self._conn = conn

    async def initialize(
        self,
        protocol_version: int,
        client_capabilities: ClientCapabilities | None = None,
        client_info: Implementation | None = None,
        **kwargs: Any,
    ) -> InitializeResponse:
        return InitializeResponse(protocol_version=protocol_version)

    def _default_model(self) -> str | None:
        if self.mode == "deterministic":
            return None
        return (
            os.environ.get("HARBOR_ACP_REQUESTED_MODEL")
            or os.environ.get("STARLINGS_HARBOR_MODEL")
            or "hosted-model"
        )

    def _model_option(self, model: str) -> SessionConfigOptionSelect:
        return SessionConfigOptionSelect(
            id="model",
            name="Model",
            category="model",
            current_value=model,
            options=[SessionConfigSelectOption(value=model, name=model)],
        )

    async def new_session(
        self,
        cwd: str,
        additional_directories: list[str] | None = None,
        mcp_servers: list[HttpMcpServer | SseMcpServer | McpServerStdio] | None = None,
        **kwargs: Any,
    ) -> NewSessionResponse:
        session_id = uuid4().hex
        model = self._default_model()
        self._sessions[session_id] = Session(cwd=cwd, model=model)
        if model is None:
            return NewSessionResponse(session_id=session_id)
        return NewSessionResponse(
            session_id=session_id,
            config_options=[self._model_option(model)],
        )

    async def set_config_option(
        self,
        config_id: str,
        session_id: str,
        value: str | bool,
        **kwargs: Any,
    ) -> SetSessionConfigOptionResponse | None:
        if config_id != "model" or not isinstance(value, str):
            return None
        state = self._sessions[session_id]
        if self.mode == "deterministic":
            return None
        state.model = value
        os.environ["STARLINGS_HARBOR_MODEL"] = value
        return SetSessionConfigOptionResponse(
            config_options=[self._model_option(value)]
        )

    async def _shell(
        self,
        session_id: str,
        state: Session,
        command: str,
    ) -> dict[str, Any]:
        created = await self._conn.create_terminal(
            session_id=session_id,
            command="/bin/sh",
            args=["-lc", command],
            cwd=state.cwd,
            output_byte_limit=65536,
        )
        try:
            exit_status = await self._conn.wait_for_terminal_exit(
                session_id=session_id,
                terminal_id=created.terminal_id,
            )
            output = await self._conn.terminal_output(
                session_id=session_id,
                terminal_id=created.terminal_id,
            )
        finally:
            await self._conn.release_terminal(
                session_id=session_id,
                terminal_id=created.terminal_id,
            )
        return {
            "command": command,
            "output": output.output,
            "truncated": output.truncated,
            "exit_code": exit_status.exit_code,
            "signal": exit_status.signal,
        }

    async def _emit_final(self, session_id: str, answer: str) -> PromptResponse:
        chunk = AgentMessageChunk(content=TextContentBlock(text=answer))
        chunk.field_meta = {"starlings_condition": self.mode}
        await self._conn.session_update(
            session_id=session_id,
            update=chunk,
            source="starlings_harbor",
        )
        return PromptResponse(stop_reason="end_turn")

    async def _baseline(
        self, session_id: str, state: Session, task: str
    ) -> PromptResponse:
        if not state.model:
            raise RuntimeError("baseline condition requires a hosted model")
        for _ in range(self.max_turns):
            decision = await asyncio.to_thread(
                decide,
                task,
                history_text(state.history),
                state.model,
            )
            if decision.kind == "final":
                return await self._emit_final(session_id, decision.value)
            result = await self._shell(session_id, state, decision.value)
            state.history.append(result)
        return await self._emit_final(session_id, "Turn budget exhausted.")

    async def _bridge_run(
        self, session_id: str, state: Session, task: str
    ) -> PromptResponse:
        if self.mode == "starlings" and not state.model:
            raise RuntimeError("Starlings condition requires a hosted model")
        if state.model:
            os.environ["STARLINGS_HARBOR_MODEL"] = state.model

        pack = "model" if self.mode == "starlings" else "deterministic"
        state.bridge = await StarlingsBridge.start(pack)
        try:
            decision = await state.bridge.start_task(task)
            for _ in range(self.max_turns):
                if decision.kind == "final":
                    return await self._emit_final(session_id, decision.value)
                if decision.kind == "error":
                    raise RuntimeError("Starlings bridge: " + decision.value)
                if decision.kind != "action":
                    return await self._emit_final(
                        session_id, "Starlings quiesced without a final answer."
                    )

                result = await self._shell(session_id, state, decision.value)
                state.history.append(result)
                decision = await state.bridge.update_history(
                    history_text(state.history)
                )
            return await self._emit_final(session_id, "Turn budget exhausted.")
        finally:
            await state.bridge.close()
            state.bridge = None

    async def prompt(
        self,
        session_id: str,
        prompt: list[
            TextContentBlock
            | ImageContentBlock
            | AudioContentBlock
            | ResourceContentBlock
            | EmbeddedResourceContentBlock
        ],
        **kwargs: Any,
    ) -> PromptResponse:
        task = _prompt_text(prompt)
        state = self._sessions[session_id]
        if self.mode == "baseline":
            return await self._baseline(session_id, state, task)
        return await self._bridge_run(session_id, state, task)

    async def cancel(self, session_id: str, **kwargs: Any) -> None:
        state = self._sessions.get(session_id)
        if state and state.bridge:
            await state.bridge.close()
            state.bridge = None
