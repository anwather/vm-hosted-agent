"""Deploy a VM-builder hosted agent (Windows or Linux variant) to Microsoft Foundry.

The same container image serves both the Windows and Linux VM-builder hosted
agents — behavior is differentiated via per-agent env vars (system prompt
file, template subfolder, allowed OS image enum). This script deploys ONE
hosted agent per invocation; pass ``--target windows`` or ``--target linux``
(default ``windows`` for back-compat).

Usage::

    az login
    set FOUNDRY_PROJECT_ENDPOINT=https://multi-agent-demo-6rd2sd.services.ai.azure.com/api/projects/multi-agent-demo-v1
    set CONTAINER_IMAGE=vmagentacrrba7ch.azurecr.io/vmagent-agent:0.2.2
    set TFSTATE_STORAGE_ACCOUNT_NAME=vmagentstrba7ch
    set TFSTATE_RESOURCE_GROUP=multi-agent-demo
    set KEYVAULT_URI=https://vmagentkvrba7ch.vault.azure.net/
    set VM_TARGET_SUBSCRIPTION_ID=01e2f327-74ac-451e-8ad9-1f923a06d634
    python deploy/deploy_agent.py --target windows
    python deploy/deploy_agent.py --target linux

Prints ``AGENT_PRINCIPAL_ID=...`` which the post-deploy RBAC script consumes
for role assignments against the per-version managed identity.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    HostedAgentDefinition,
    ProtocolVersionRecord,
)
from azure.identity import DefaultAzureCredential

PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT") or os.environ["AZURE_AI_PROJECT_ENDPOINT"]
CONTAINER_IMAGE = os.environ["CONTAINER_IMAGE"]
MODEL_DEPLOYMENT_NAME = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "gpt-5.1")

# These env vars are only required for VM-builder agents (windows/linux). The
# pricing agent has no terraform / KV / VM-target subscription dependency, so
# we pull them lazily via os.environ.get() inside the env-var injection block.


# Per-agent profile: name + image-internal config that selects role-specific
# behavior. The "role" key is passed into the container as ``VM_AGENT_ROLE``
# (Foundry reserves the ``AGENT_*`` prefix, so we cannot use ``AGENT_ROLE``).
AGENT_PROFILES: dict[str, dict[str, str]] = {
    "windows": {
        "agent_name": os.environ.get("HOSTED_AGENT_NAME", "vmagent-agent"),
        "description": "Conversational Windows VM deployer (Terraform-backed).",
        "role": "vm-builder",
        "system_prompt_file": "system_prompt_windows.txt",
        "template_subfolder": "windows",
        "allowed_os_images_json": json.dumps(
            ["WindowsServer2022-smalldisk", "WindowsServer2025-smalldisk"]
        ),
    },
    "linux": {
        "agent_name": os.environ.get("HOSTED_AGENT_NAME_LINUX", "vmagent-agent-linux"),
        "description": "Conversational Linux VM deployer (Terraform-backed).",
        "role": "vm-builder",
        "system_prompt_file": "system_prompt_linux.txt",
        "template_subfolder": "linux",
        "allowed_os_images_json": json.dumps(["Ubuntu2204", "Ubuntu2404", "RHEL9"]),
    },
    "pricing": {
        "agent_name": os.environ.get("HOSTED_AGENT_NAME_PRICING", "vmagent-agent-pricing"),
        "description": "Cost estimator for VM SKUs (Azure Retail Prices, AUD).",
        "role": "pricing",
        "system_prompt_file": "system_prompt_pricing.txt",
        # Pricing agent doesn't touch templates / state.
        "template_subfolder": "",
        "allowed_os_images_json": "",
    },
}


def _build_env(profile: dict[str, str], agent_name: str, target: str) -> dict[str, str]:
    """Assemble the env vars injected into the hosted agent container.

    For ``vm-builder`` agents (windows/linux) we inject the full terraform /
    KV / target-subscription stack. For ``pricing`` we skip those — the
    pricing tool only hits the public Azure Retail Prices API and needs no
    subscription wiring.
    """
    env: dict[str, str] = {
        # FOUNDRY_*, AGENT_*, APPLICATIONINSIGHTS_* are reserved by the
        # Foundry hosting layer and injected automatically — using them
        # here causes a 400 from create_version.
        "AZURE_AI_MODEL_DEPLOYMENT_NAME": MODEL_DEPLOYMENT_NAME,
        "HOSTED_AGENT_NAME": agent_name,
        "VM_AGENT_ROLE": profile["role"],
        "SYSTEM_PROMPT_FILE": profile["system_prompt_file"],
    }
    if profile["role"] == "vm-builder":
        env.update({
            "TFSTATE_STORAGE_ACCOUNT_NAME": os.environ["TFSTATE_STORAGE_ACCOUNT_NAME"],
            "TFSTATE_CONTAINER_NAME": os.environ.get("TFSTATE_CONTAINER_NAME", "tfstate"),
            "TFSTATE_RESOURCE_GROUP": os.environ["TFSTATE_RESOURCE_GROUP"],
            "KEYVAULT_URI": os.environ["KEYVAULT_URI"],
            "VM_TARGET_SUBSCRIPTION_ID": os.environ["VM_TARGET_SUBSCRIPTION_ID"],
            "VM_OS_FAMILY": target,
            "TEMPLATE_SUBFOLDER": profile["template_subfolder"],
            "ALLOWED_OS_IMAGES_JSON": profile["allowed_os_images_json"],
        })
    return env


def main() -> int:
    parser = argparse.ArgumentParser(description="Deploy a VM-builder hosted agent.")
    parser.add_argument(
        "--target",
        choices=sorted(AGENT_PROFILES.keys()),
        default=os.environ.get("AGENT_TARGET", "windows"),
        help="Which agent variant to deploy (windows | linux | pricing).",
    )
    args = parser.parse_args()
    profile = AGENT_PROFILES[args.target]
    agent_name = profile["agent_name"]

    client = AIProjectClient(
        endpoint=PROJECT_ENDPOINT,
        credential=DefaultAzureCredential(),
        allow_preview=True,
    )

    print(
        f"Creating hosted agent version: target={args.target} "
        f"role={profile['role']} name={agent_name} image={CONTAINER_IMAGE}"
    )
    agent = client.agents.create_version(
        agent_name=agent_name,
        description=profile["description"],
        definition=HostedAgentDefinition(
            cpu="1",
            memory="2Gi",
            image=CONTAINER_IMAGE,
            container_protocol_versions=[
                ProtocolVersionRecord(protocol="responses", version="1.0.0"),
            ],
            environment_variables=_build_env(profile, agent_name, args.target),
        ),
        metadata={"enableVnextExperience": "true"},
    )
    print(f"create_version returned: name={agent.name} version={getattr(agent, 'version', '?')}")

    # Poll for active using `agent_version=` (matches official sample)
    deadline = time.time() + 30 * 60
    last_state = None

    def _state_str(s):
        if s is None:
            return ""
        v = getattr(s, "value", s)
        return str(v).lower()

    while time.time() < deadline:
        v = client.agents.get_version(agent_name=agent_name, agent_version=agent.version)
        state = getattr(v, "status", None) or getattr(v, "provisioning_state", None)
        if state != last_state:
            print(f"  status={state}")
            last_state = state
        s = _state_str(state)
        if s in ("active", "succeeded"):
            identity = (
                getattr(v, "instance_identity", None)
                or getattr(v, "identity", None)
                or getattr(v, "managed_identity", None)
            )
            principal_id = None
            if identity is not None:
                if isinstance(identity, dict):
                    principal_id = identity.get("principal_id") or identity.get("object_id")
                else:
                    principal_id = (
                        getattr(identity, "principal_id", None)
                        or getattr(identity, "object_id", None)
                    )
            print(f"Agent active. principal_id={principal_id}")
            print(f"AGENT_NAME={agent_name}")
            print(f"AGENT_PRINCIPAL_ID={principal_id}")
            print(f"AGENT_VERSION={agent.version}")
            return 0
        if s in ("failed", "canceled", "cancelled"):
            print(f"Agent provisioning failed: {state}")
            try:
                print("Version details:")
                print(json.dumps(dict(v), indent=2, default=str))
            except Exception as exc:
                print(f"(could not dump details: {exc})")
            return 2
        time.sleep(15)
    print("Timed out waiting for agent to become active")
    return 3


if __name__ == "__main__":
    sys.exit(main())
