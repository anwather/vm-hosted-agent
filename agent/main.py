"""Foundry Hosted Agent — VM deployment orchestrator.

Currently a minimal Responses-protocol echo handler.
Tools (clone_repo, generate_admin_password, terraform_*) are added in subsequent todos.
"""
from __future__ import annotations

import asyncio
import logging
import os

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    TextResponse,
)

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("vmagent")

app = ResponsesAgentServerHost()


@app.response_handler
async def handler(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal: asyncio.Event,
):
    text = await context.get_input_text()
    logger.info("received input: %r", text)
    return TextResponse(context, request, text=f"vmagent echo: {text}")


def main() -> None:
    app.run()


if __name__ == "__main__":
    main()
