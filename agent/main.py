"""Foundry Hosted Agent — VM deployment orchestrator.

Canonical pattern from
https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/02-tools

`ResponsesHostServer` from `agent_framework_foundry_hosting` exposes the
Responses-protocol HTTP server on port 8088 that Foundry calls.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential

from tools.registry import ALL_TOOLS, PRICING_TOOLS

# Optional Application Insights wiring
_AI_CONN = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
if _AI_CONN:
    try:
        from azure.monitor.opentelemetry import configure_azure_monitor

        configure_azure_monitor(connection_string=_AI_CONN)
    except Exception:  # noqa: BLE001
        pass

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("vmagent")

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
MODEL_DEPLOYMENT_NAME = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "gpt-5.1")
AGENT_NAME = os.environ.get("HOSTED_AGENT_NAME", "vmagent-agent-windows")

# The same container image serves three hosted-agent roles. Foundry rejects
# env-var names with the reserved ``AGENT_*`` / ``FOUNDRY_*`` prefixes, so we
# use ``VM_AGENT_ROLE`` instead. Valid values:
#   * ``vm-builder`` (default) — Windows or Linux specialist with the full
#     terraform tool set. Distinguished further by SYSTEM_PROMPT_FILE +
#     TEMPLATE_SUBFOLDER + ALLOWED_OS_IMAGES_JSON env vars.
#   * ``pricing`` — pricing specialist. Loads system_prompt_pricing.txt by
#     default, exposes only ``PRICING_TOOLS``.
VM_AGENT_ROLE = os.environ.get("VM_AGENT_ROLE", "vm-builder").strip().lower()

if VM_AGENT_ROLE == "pricing":
    _DEFAULT_PROMPT_FILE = "system_prompt_pricing.txt"
    TOOLS = list(PRICING_TOOLS)
else:
    _DEFAULT_PROMPT_FILE = "system_prompt_windows.txt"
    TOOLS = list(ALL_TOOLS)

SYSTEM_PROMPT_FILE = os.environ.get("SYSTEM_PROMPT_FILE", _DEFAULT_PROMPT_FILE)
SYSTEM_PROMPT = (Path(__file__).parent / SYSTEM_PROMPT_FILE).read_text(encoding="utf-8")


def main() -> None:
    credential = DefaultAzureCredential()
    client = FoundryChatClient(
        project_endpoint=PROJECT_ENDPOINT,
        model=MODEL_DEPLOYMENT_NAME,
        credential=credential,
    )

    agent = Agent(
        client=client,
        name=AGENT_NAME,
        instructions=SYSTEM_PROMPT,
        tools=TOOLS,
        # Foundry's hosting layer manages conversation history, so disable
        # local persistence (store=False) per the canonical sample.
        default_options={"store": False},
    )

    logger.info(
        "Starting %s role=%s model=%s endpoint=%s tools=%d prompt=%s",
        AGENT_NAME, VM_AGENT_ROLE, MODEL_DEPLOYMENT_NAME, PROJECT_ENDPOINT,
        len(TOOLS), SYSTEM_PROMPT_FILE,
    )
    ResponsesHostServer(agent).run()


if __name__ == "__main__":
    main()
