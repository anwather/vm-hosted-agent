"""generate_admin_password tool.

Generates a strong Windows-compatible password, stores it in Key Vault as
`vm-<vm_name>-admin`, and returns ONLY the secret URI. The cleartext value is
never returned to the model or logged.
"""
from __future__ import annotations

import os
import re
import secrets
import string
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

LOWER = string.ascii_lowercase
UPPER = string.ascii_uppercase
DIGIT = string.digits
SYMBOL = "!@#$%^&*()-_=+[]{}"


def _generate(length: int = 24) -> str:
    if length < 12:
        length = 12
    pool = LOWER + UPPER + DIGIT + SYMBOL
    while True:
        pw = "".join(secrets.choice(pool) for _ in range(length))
        if (
            any(c in LOWER for c in pw)
            and any(c in UPPER for c in pw)
            and any(c in DIGIT for c in pw)
            and any(c in SYMBOL for c in pw)
        ):
            return pw


def _safe_secret_name(vm_name: str) -> str:
    base = re.sub(r"[^a-zA-Z0-9-]", "-", vm_name).strip("-").lower()
    return f"vm-{base or 'vm'}-admin"[:127]


def generate_admin_password(vm_name: str) -> dict[str, Any]:
    kv_uri = os.environ.get("KEYVAULT_URI")
    if not kv_uri:
        return {"ok": False, "error": "KEYVAULT_URI env var not set"}

    pw = _generate(24)
    secret_name = _safe_secret_name(vm_name)

    cred = DefaultAzureCredential()
    client = SecretClient(vault_url=kv_uri, credential=cred)
    secret = client.set_secret(secret_name, pw, content_type="text/plain")

    return {
        "ok": True,
        "secret_name": secret_name,
        "secret_uri": secret.id,  # versioned URI
        "vault_url": kv_uri,
        "password_length": len(pw),
    }
