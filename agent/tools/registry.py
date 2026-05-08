"""Tool functions wired into the agent-framework ChatAgent.

Each function is decorated with `@tool` so the agent-framework can expose it as a
function-calling tool to the model. Session/workdir scoping uses an env var
`AGENT_SESSION_ID` set per request via middleware (defaults to `default`).

The same container image serves three roles selected via ``VM_AGENT_ROLE``:

* ``vm-builder`` (default) — Windows or Linux specialist, exposes the full
  terraform tool set (``ALL_TOOLS``).
* ``pricing`` — exposes only the pricing tool (``PRICING_TOOLS``).
"""
from __future__ import annotations

import os
from typing import Annotated, Any

from agent_framework import tool
from pydantic import Field

from .git_clone import clone_template_repo as _clone
from .password import generate_admin_password as _gen_pw
from .pricing import get_vm_monthly_cost as _get_vm_monthly_cost
from .terraform import (
    _allowed_os_images,
    get_deployment_status as _get_status,
    set_tf_variables as _set_vars,
    terraform_apply as _apply,
    terraform_init as _init,
    terraform_plan as _plan,
    workspace_status as _ws_status,
)


_OS_IMAGES_DESC = "One of: " + ", ".join(_allowed_os_images())


def _sid() -> str | None:
    return os.environ.get("AGENT_SESSION_ID")


@tool(approval_mode="never_require")
def clone_template_repo(
    branch: Annotated[
        str | None,
        Field(default=None, description="Optional branch to checkout. Defaults to repo default."),
    ] = None,
) -> dict[str, Any]:
    """Clone the curated VM Terraform template into the session workspace.

    The same template repo serves both Windows and Linux VM-builder agents;
    the active subfolder is selected via the ``TEMPLATE_SUBFOLDER`` env var.
    """
    return _clone(_sid(), branch=branch)


@tool(approval_mode="never_require")
def generate_admin_password(
    vm_name: Annotated[str, Field(description="VM name; used to derive the Key Vault secret name.")],
) -> dict[str, Any]:
    """Generate a strong admin password and store it in Key Vault.

    Returns the secret URI ONLY. Never returns or logs the cleartext password.
    """
    return _gen_pw(vm_name)


@tool(approval_mode="never_require")
def set_tf_variables(
    vm_name: Annotated[str, Field(description="VM name (lowercase letters/digits/hyphen). Windows agents must additionally honour the 15-char NetBIOS limit.")],
    resource_group: Annotated[str, Field(description="Resource group for the VM. Created by the template if missing.")],
    location: Annotated[str, Field(description="Azure region, e.g. australiaeast")],
    size: Annotated[str, Field(description="Azure VM size, e.g. Standard_D2s_v5 or Standard_B2s")],
    os_image: Annotated[
        str,
        Field(description=_OS_IMAGES_DESC),
    ],
    admin_username: Annotated[str, Field(description="Local admin username (not a reserved name like admin/root/administrator)")],
    subnet_id: Annotated[
        str,
        Field(
            description=(
                "Full Azure resource ID of an EXISTING subnet, e.g. /subscriptions/.../resourceGroups/"
                "<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"
            ),
        ),
    ],
) -> dict[str, Any]:
    """Write terraform.tfvars.json into the cloned template workspace.

    The template generates the admin password internally (random_password)
    and emits its Key Vault secret URI in the apply outputs — so this tool
    does NOT take a password.
    """
    return _set_vars(
        _sid(),
        vm_name=vm_name,
        resource_group=resource_group,
        location=location,
        size=size,
        os_image=os_image,
        admin_username=admin_username,
        subnet_id=subnet_id,
    )


@tool(approval_mode="never_require")
def terraform_init() -> dict[str, Any]:
    """Run `terraform init` against the azurerm backend (per-session state key)."""
    return _init(_sid())


@tool(approval_mode="never_require")
def terraform_plan() -> dict[str, Any]:
    """Run `terraform plan -out=tfplan.binary` and return a brief change summary."""
    return _plan(_sid())


@tool(approval_mode="never_require")
def terraform_apply() -> dict[str, Any]:
    """Start `terraform apply` in the background. Returns a job_id; poll get_deployment_status."""
    return _apply(_sid())


@tool(approval_mode="never_require")
def get_deployment_status(
    job_id: Annotated[str, Field(description="Job id returned by terraform_apply")],
) -> dict[str, Any]:
    """Poll a running terraform apply: returns terminal flag, phase, log tail, and outputs when done."""
    return _get_status(_sid(), job_id)


@tool(approval_mode="never_require")
def get_vm_monthly_cost(
    vm_size: Annotated[str, Field(description="Azure VM SKU, e.g. Standard_D2s_v5 or Standard_B2s")],
    region: Annotated[
        str,
        Field(
            default="australiaeast",
            description="Azure region short code, e.g. australiaeast. Default australiaeast.",
        ),
    ] = "australiaeast",
    os_type: Annotated[
        str,
        Field(
            default="linux",
            description="VM operating system family: 'linux' or 'windows'. Default linux.",
        ),
    ] = "linux",
) -> dict[str, Any]:
    """Return an approximate monthly compute cost in AUD for a single Azure VM.

    Hits the public Azure Retail Prices API; no auth required. Compute only —
    excludes disk, network egress, backups, snapshots, and reserved-instance
    discounts. Hourly rate × 730 hrs/mo.
    """
    return _get_vm_monthly_cost(vm_size=vm_size, region=region, os_type=os_type)


@tool(approval_mode="never_require")
def workspace_status() -> dict[str, Any]:
    """Inspect the per-session workspace state without modifying it.

    Returns flags indicating whether the template is cloned, tfvars are
    written, init has run, and a plan is on disk — plus the parsed tfvars
    so you can confirm the captured parameters. Call this on resume (e.g.
    after a handback from the pricing agent) so you can skip steps that
    are already done and avoid wiping in-flight work.
    """
    return _ws_status(_sid())


# Default tool set for the Windows / Linux specialist hosted agents.
ALL_TOOLS = [
    workspace_status,
    clone_template_repo,
    set_tf_variables,
    terraform_init,
    terraform_plan,
    terraform_apply,
    get_deployment_status,
]

# Tool set for the pricing hosted agent (VM_AGENT_ROLE=pricing). The pricing
# agent never deploys anything.
PRICING_TOOLS = [
    get_vm_monthly_cost,
]
