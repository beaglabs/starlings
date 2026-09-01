#!/usr/bin/env python3
"""Small in-sandbox MCP client used by Starlings' shell action surface.

The Harbor agent stays outside the task sandbox. For streamable-http MCP servers
whose DNS names are visible only inside the task network, the model invokes this
helper through environment.exec().
"""

from __future__ import annotations

import argparse
import asyncio
import json
from datetime import timedelta
from typing import Any

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


def _read(item: Any, key: str, default: Any = None) -> Any:
    if isinstance(item, dict):
        return item.get(key, default)
    return getattr(item, key, default)


def _dump(item: Any) -> Any:
    if hasattr(item, "model_dump"):
        return item.model_dump(mode="json")
    if isinstance(item, list):
        return [_dump(value) for value in item]
    if isinstance(item, dict):
        return {key: _dump(value) for key, value in item.items()}
    return item


async def run(args: argparse.Namespace) -> int:
    async with streamablehttp_client(
        args.url,
        timeout=args.timeout,
        sse_read_timeout=args.timeout,
    ) as streams:
        read_stream, write_stream, _ = streams
        async with ClientSession(
            read_stream,
            write_stream,
            read_timeout_seconds=timedelta(seconds=args.timeout),
        ) as session:
            await session.initialize()
            if args.operation == "list":
                result = await session.list_tools()
                tools = _read(result, "tools", [])
                payload = []
                for tool in tools:
                    payload.append(
                        {
                            "name": _read(tool, "name"),
                            "description": _read(tool, "description"),
                            "inputSchema": _read(tool, "inputSchema", {}),
                        }
                    )
                print(json.dumps(payload, sort_keys=True))
                return 0

            arguments = json.loads(args.arguments)
            if not isinstance(arguments, dict):
                raise ValueError("tool arguments must decode to a JSON object")
            result = await session.call_tool(
                args.tool,
                arguments,
                read_timeout_seconds=timedelta(seconds=args.timeout),
            )
            print(json.dumps(_dump(result), sort_keys=True))
            return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("list", "call"))
    parser.add_argument("url")
    parser.add_argument("tool", nargs="?")
    parser.add_argument("arguments", nargs="?", default="{}")
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()

    if args.operation == "call" and not args.tool:
        parser.error("call requires TOOL and optional JSON arguments")
    return asyncio.run(run(args))


if __name__ == "__main__":
    raise SystemExit(main())
