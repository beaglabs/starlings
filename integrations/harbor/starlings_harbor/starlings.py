from __future__ import annotations

import asyncio

from acp import run_agent

from .agent import HarborExperimentAgent


async def main() -> None:
    await run_agent(HarborExperimentAgent("starlings"))


if __name__ == "__main__":
    asyncio.run(main())
