"""Assign post-deploy RBAC roles to the hosted agent's managed identity.

Required:
    AGENT_PRINCIPAL_ID — printed by deploy_agent.py
    VM_TARGET_SUBSCRIPTION_ID
    TFSTATE_STORAGE_ACCOUNT_ID  — full resource id
    KEYVAULT_ID                 — full resource id
    FOUNDRY_PROJECT_ID          — full resource id of the Foundry project (Microsoft.CognitiveServices/accounts/<acct>/projects/<proj>)
    FOUNDRY_ACCOUNT_ID          — full resource id of the underlying CognitiveServices account

Use ``--target {windows,linux,pricing}`` to scope which roles to assign:
    windows/linux → all roles (terraform + KV + Foundry)
    pricing       → Foundry roles only (no terraform / KV / target sub)
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys


# (env_var_holding_scope_value, role_name, scope_template, role_kind)
# role_kind: "vm-builder" or "foundry" — pricing role only needs "foundry".
ROLES = [
    ("VM_TARGET_SUBSCRIPTION_ID", "Contributor", "/subscriptions/{}", "vm-builder"),
    ("TFSTATE_STORAGE_ACCOUNT_ID", "Storage Blob Data Contributor", "{}", "vm-builder"),
    ("KEYVAULT_ID", "Key Vault Secrets Officer", "{}", "vm-builder"),
    ("FOUNDRY_PROJECT_ID", "Azure AI User", "{}", "foundry"),
    ("FOUNDRY_ACCOUNT_ID", "Cognitive Services OpenAI User", "{}", "foundry"),
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--target",
        choices=("windows", "linux", "pricing"),
        default=os.environ.get("AGENT_TARGET", "windows"),
        help="Selects which role set applies. 'pricing' skips terraform/KV/target-sub roles.",
    )
    args = parser.parse_args()

    principal = os.environ["AGENT_PRINCIPAL_ID"]
    needed_kinds = {"foundry"} if args.target == "pricing" else {"vm-builder", "foundry"}

    failures = 0
    for env_name, role, scope_template, kind in ROLES:
        if kind not in needed_kinds:
            print(f"skip {role}: not required for target={args.target}")
            continue
        value = os.environ.get(env_name)
        if not value:
            print(f"skip {role}: {env_name} not set")
            continue
        scope = scope_template.format(value)
        print(f"Assigning {role!r} to {principal} at {scope}")
        rc = subprocess.call(
            [
                "az", "role", "assignment", "create",
                "--assignee-object-id", principal,
                "--assignee-principal-type", "ServicePrincipal",
                "--role", role,
                "--scope", scope,
            ],
            shell=True,
        )
        if rc != 0:
            failures += 1
            print(f"FAILED ({rc}) for {role}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
