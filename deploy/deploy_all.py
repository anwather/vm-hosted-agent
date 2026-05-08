"""One-shot deployment driver for Task Orchestrator.

Deploys (or refreshes) the persistent orchestrator AND both Windows + Linux
hosted agents using the SAME container image, then runs the post-deploy RBAC
assignment for each new hosted-agent version's per-version managed identity.

This is the canonical "after I've built the image, push everything to Foundry
and make the new MIs work" entry point. Idempotent: run as many times as you
like — each run just creates a new agent version.

Required env vars (all readable from infra outputs except the Foundry endpoint):

    FOUNDRY_PROJECT_ENDPOINT    https://<acct>.services.ai.azure.com/api/projects/<proj>
    CONTAINER_IMAGE             <acr>.azurecr.io/vmagent-agent:<tag>
    TFSTATE_STORAGE_ACCOUNT_NAME
    TFSTATE_RESOURCE_GROUP
    KEYVAULT_URI
    VM_TARGET_SUBSCRIPTION_ID
    FOUNDRY_RG                  resource group of the CognitiveServices account
    FOUNDRY_ACCOUNT_NAME        name of the CognitiveServices account
    FOUNDRY_PROJECT_NAME        project name (last segment of the endpoint)

Optional:
    AZURE_AI_MODEL_DEPLOYMENT_NAME (default: gpt-5.1)
    HOSTED_AGENT_NAME              (default: vmagent-agent)
    HOSTED_AGENT_NAME_LINUX        (default: vmagent-agent-linux)
    ORCHESTRATOR_AGENT_NAME        (default: taskorch-orchestrator)
    KEYVAULT_NAME                  (derived from KEYVAULT_URI if not set)

Usage::

    az login
    python deploy/deploy_all.py
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent


def _required(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        sys.exit(f"Missing required env var: {name}")
    return val


def _run_capture(cmd: list[str], extra_env: dict[str, str] | None = None) -> str:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    print(f"\n>>> {' '.join(cmd)}")
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.exit(f"Command failed (rc={proc.returncode}): {' '.join(cmd)}")
    return proc.stdout


def _parse_principal(stdout: str) -> str | None:
    m = re.search(r"AGENT_PRINCIPAL_ID=([\w-]+)", stdout)
    return m.group(1) if m and m.group(1) != "None" else None


def _kv_id() -> str:
    name = os.environ.get("KEYVAULT_NAME")
    if not name:
        # derive from URI: https://<name>.vault.azure.net/
        m = re.match(r"https?://([^.]+)\.vault\.azure\.net/?", _required("KEYVAULT_URI"))
        if not m:
            sys.exit("KEYVAULT_URI not parseable; set KEYVAULT_NAME explicitly.")
        name = m.group(1)
    rg = _required("TFSTATE_RESOURCE_GROUP")  # KV lives alongside tfstate in this design
    sub = _required("VM_TARGET_SUBSCRIPTION_ID")
    return f"/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{name}"


def _storage_id() -> str:
    sub = _required("VM_TARGET_SUBSCRIPTION_ID")
    rg = _required("TFSTATE_RESOURCE_GROUP")
    name = _required("TFSTATE_STORAGE_ACCOUNT_NAME")
    return f"/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}"


def _foundry_account_id() -> str:
    sub = _required("VM_TARGET_SUBSCRIPTION_ID")
    rg = _required("FOUNDRY_RG")
    name = _required("FOUNDRY_ACCOUNT_NAME")
    return f"/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.CognitiveServices/accounts/{name}"


def _foundry_project_id() -> str:
    return f"{_foundry_account_id()}/projects/{_required('FOUNDRY_PROJECT_NAME')}"


def _assign_rbac(principal_id: str, target: str) -> None:
    extra = {
        "AGENT_PRINCIPAL_ID": principal_id,
        "AGENT_TARGET": target,
        "TFSTATE_STORAGE_ACCOUNT_ID": _storage_id(),
        "KEYVAULT_ID": _kv_id(),
        "FOUNDRY_ACCOUNT_ID": _foundry_account_id(),
        "FOUNDRY_PROJECT_ID": _foundry_project_id(),
    }
    _run_capture(
        [sys.executable, str(HERE / "assign_rbac.py"), "--target", target],
        extra_env=extra,
    )


def main() -> int:
    # Sanity-check required vars early
    for name in (
        "FOUNDRY_PROJECT_ENDPOINT", "CONTAINER_IMAGE",
        "TFSTATE_STORAGE_ACCOUNT_NAME", "TFSTATE_RESOURCE_GROUP",
        "KEYVAULT_URI", "VM_TARGET_SUBSCRIPTION_ID",
        "FOUNDRY_RG", "FOUNDRY_ACCOUNT_NAME", "FOUNDRY_PROJECT_NAME",
    ):
        _required(name)

    # 1. Orchestrator (persistent agent)
    _run_capture([sys.executable, str(HERE / "deploy_orchestrator.py")])

    # 2-4. All three hosted agents (Windows VM builder, Linux VM builder,
    # pricing). Pricing reuses the same image but a different role + tool set.
    for target in ("windows", "linux", "pricing"):
        out = _run_capture(
            [sys.executable, str(HERE / "deploy_agent.py"), "--target", target]
        )
        principal = _parse_principal(out)
        if not principal:
            sys.exit(f"Could not parse AGENT_PRINCIPAL_ID for target={target}")
        # 5. RBAC for the new MI (pricing only gets Foundry roles).
        _assign_rbac(principal, target)

    print("\n=== deploy_all complete ===")
    print("Now (re)deploy the frontend container app with the new env vars:")
    print("  ORCHESTRATOR_AGENT_NAME=taskorch-orchestrator")
    print("  HOSTED_AGENT_NAME_WINDOWS=vmagent-agent")
    print("  HOSTED_AGENT_NAME_LINUX=vmagent-agent-linux")
    print("  HOSTED_AGENT_NAME_PRICING=vmagent-agent-pricing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
