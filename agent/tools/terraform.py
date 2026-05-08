"""Terraform tool wrappers (init / plan / apply / set_tf_variables).

Conventions:
* Working directory is the per-session `template/` folder populated by
  `clone_template_repo`.
* Backend: `azurerm`. Storage account / container come from env vars set on the
  hosted-agent container; the state key is `<sub>.<rg>.<vm_name>.tfstate`,
  derived from `terraform.tfvars.json` written by `set_tf_variables`.
* `terraform_apply` runs in the background and returns a job_id. Status is
  polled via `get_deployment_status`.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import uuid
from pathlib import Path
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

from .workspace import jobs_dir, template_dir

PLAN_FILE = "tfplan.binary"
TFVARS_FILE = "terraform.tfvars.json"
INIT_MARKER = ".tf-init-ok"


# ---------------------------------------------------------------------------
# Helpers


_AZ_LOGIN_DONE = False


def _ensure_az_cli_login() -> tuple[bool, str]:
    """Run `az login --identity` once per process so terraform CLI auth works.

    Foundry hosted-agent containers expose the managed identity through
    `IDENTITY_ENDPOINT` + `IDENTITY_HEADER` (App Service / Container Apps
    style) and have NO IMDS endpoint. The Azure CLI's `--identity` flag
    understands this protocol; terraform's azurerm provider/backend MSI
    authorizers only probe IMDS at 169.254.169.254 and fail. So we log the
    CLI in once, then run terraform with `ARM_USE_CLI=true`.
    """
    global _AZ_LOGIN_DONE
    if _AZ_LOGIN_DONE:
        return True, ""

    cmd = ["az", "login", "--identity", "--allow-no-subscriptions"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return False, "az CLI not found in PATH"
    except subprocess.TimeoutExpired:
        return False, "az login --identity timed out after 60s"

    if proc.returncode != 0:
        return False, f"az login --identity failed: {proc.stderr.strip() or proc.stdout.strip()}"

    sub = os.environ.get("VM_TARGET_SUBSCRIPTION_ID")
    if sub:
        subprocess.run(
            ["az", "account", "set", "--subscription", sub],
            capture_output=True, text=True, timeout=30,
        )

    _AZ_LOGIN_DONE = True
    return True, ""


def _tf_env() -> dict[str, str]:
    """Environment for terraform subprocesses.

    Uses `ARM_USE_CLI=true`. Foundry hosted-agent containers expose the MI
    via App Service-style env vars (`IDENTITY_ENDPOINT`/`IDENTITY_HEADER`)
    and have no IMDS endpoint. Terraform's azurerm backend/provider MSI
    authorizers only probe IMDS, so they fail. The Azure CLI does understand
    the App Service env vars, so we log it in once with `_ensure_az_cli_login`
    and tell terraform to delegate auth to the CLI.
    """
    env = os.environ.copy()
    env["ARM_USE_MSI"] = "false"
    env["ARM_USE_CLI"] = "true"
    env["ARM_USE_OIDC"] = "false"
    if sub := os.environ.get("VM_TARGET_SUBSCRIPTION_ID"):
        env["ARM_SUBSCRIPTION_ID"] = sub
    if tenant := os.environ.get("AZURE_TENANT_ID"):
        env["ARM_TENANT_ID"] = tenant
    return env


def _run_tf(cmd: list[str], workdir: Path, timeout: int) -> tuple[int, str, str]:
    """Run terraform, returning (exit_code, stdout, stderr).

    Converts a TimeoutExpired into a non-zero return so the agent surfaces a
    clear error instead of crashing the tool call.
    """
    try:
        proc = subprocess.run(
            cmd,
            cwd=workdir,
            env=_tf_env(),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or b"")
        err = (exc.stderr or b"")
        if isinstance(out, bytes):
            out = out.decode("utf-8", "replace")
        if isinstance(err, bytes):
            err = err.decode("utf-8", "replace")
        return (
            124,
            out,
            err
            + f"\n[tool] terraform timed out after {timeout}s while running: {' '.join(cmd)}\n",
        )


def _resolve_secret_uri(uri: str) -> str:
    """Fetch a Key Vault secret value from a versioned/unversioned URI."""
    m = re.match(r"^(https://[^/]+)/secrets/([^/]+)(?:/([^/]+))?", uri)
    if not m:
        raise ValueError(f"Not a Key Vault secret URI: {uri!r}")
    vault_url, name, version = m.group(1), m.group(2), m.group(3)
    cred = DefaultAzureCredential()
    client = SecretClient(vault_url=vault_url, credential=cred)
    sec = client.get_secret(name, version)
    return sec.value


# ---------------------------------------------------------------------------
# set_tf_variables


def _allowed_os_images() -> list[str]:
    """OS image enum allowed by the active VM template.

    Driven by the ``ALLOWED_OS_IMAGES_JSON`` env var so the same container
    image can serve both the Windows and Linux hosted agents. Defaults to
    the original Windows set for back-compat.
    """
    raw = os.environ.get("ALLOWED_OS_IMAGES_JSON")
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list) and all(isinstance(x, str) for x in data):
                return data
        except (ValueError, TypeError):
            pass
    return ["WindowsServer2022-smalldisk", "WindowsServer2025-smalldisk"]


_ALLOWED_OS_IMAGES = set(_allowed_os_images())


def set_tf_variables(
    session_id: str | None,
    vm_name: str,
    resource_group: str,
    location: str,
    size: str,
    os_image: str,
    admin_username: str,
    subnet_id: str,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Write `terraform.tfvars.json` for the cloned template.

    The template (`anwather/vm-template-repo`) generates the admin password
    itself via `random_password`, so this tool does NOT supply one — and
    must not, since the template doesn't declare an `admin_password`
    variable. Required keys mirror the seven variables in `variables.tf`.
    """
    workdir = template_dir(session_id)
    if not workdir.exists():
        return {"ok": False, "error": "template not cloned yet"}

    if os_image not in _ALLOWED_OS_IMAGES:
        return {
            "ok": False,
            "error": (
                f"os_image must be one of {sorted(_ALLOWED_OS_IMAGES)}; got {os_image!r}"
            ),
        }
    if not subnet_id.startswith("/subscriptions/") or "/subnets/" not in subnet_id:
        return {
            "ok": False,
            "error": (
                "subnet_id must be a full subnet resource id of the form "
                "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/"
                "virtualNetworks/<vnet>/subnets/<subnet>"
            ),
        }

    payload: dict[str, Any] = {
        "vm_name": vm_name,
        "resource_group": resource_group,
        "location": location,
        "vm_size": size,
        "os_image": os_image,
        "admin_username": admin_username,
        "subnet_id": subnet_id,
    }
    if extra:
        payload.update(extra)

    tfvars_path = workdir / TFVARS_FILE
    tfvars_path.write_text(json.dumps(payload, indent=2))

    return {
        "ok": True,
        "path": str(tfvars_path),
        "variables_set": sorted(payload.keys()),
    }


# ---------------------------------------------------------------------------
# terraform_init


def terraform_init(session_id: str | None) -> dict[str, Any]:
    workdir = template_dir(session_id)
    if not workdir.exists():
        return {"ok": False, "error": "template not cloned yet"}

    storage = os.environ.get("TFSTATE_STORAGE_ACCOUNT_NAME")
    container = os.environ.get("TFSTATE_CONTAINER_NAME", "tfstate")
    rg = os.environ.get("TFSTATE_RESOURCE_GROUP")
    if not storage or not rg:
        return {
            "ok": False,
            "error": "TFSTATE_STORAGE_ACCOUNT_NAME / TFSTATE_RESOURCE_GROUP env vars required",
        }

    # Build a deterministic state key from the deployment identity:
    #   <subscription_id>.<resource_group>.<vm_name>.tfstate
    # This requires set_tf_variables to have been called first (so we can read
    # vm_name + resource_group from tfvars.json). Subscription comes from the
    # VM_TARGET_SUBSCRIPTION_ID env var, or is parsed from the subnet_id.
    tfvars_path = workdir / TFVARS_FILE
    if not tfvars_path.exists():
        return {
            "ok": False,
            "error": (
                "set_tf_variables must be called before terraform_init so the "
                "state key can be derived from <sub>.<rg>.<vm_name>"
            ),
        }
    try:
        tfvars = json.loads(tfvars_path.read_text())
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"could not read {TFVARS_FILE}: {exc}"}

    vm_name = tfvars.get("vm_name")
    target_rg = tfvars.get("resource_group")
    subnet_id = tfvars.get("subnet_id", "")
    sub_id = os.environ.get("VM_TARGET_SUBSCRIPTION_ID")
    if not sub_id and subnet_id.startswith("/subscriptions/"):
        sub_id = subnet_id.split("/", 3)[2]
    if not (vm_name and target_rg and sub_id):
        return {
            "ok": False,
            "error": (
                "could not derive state key: need vm_name, resource_group, and a "
                "subscription id (from VM_TARGET_SUBSCRIPTION_ID or subnet_id)"
            ),
        }

    def _slug(s: str) -> str:
        return re.sub(r"[^A-Za-z0-9._-]", "_", s)

    state_key = f"{_slug(sub_id)}.{_slug(target_rg)}.{_slug(vm_name)}.tfstate"

    ok, err = _ensure_az_cli_login()
    if not ok:
        return {"ok": False, "error": f"az login failed: {err}", "state_key": state_key}

    cmd = [
        "terraform",
        "init",
        "-no-color",
        "-input=false",
        f"-backend-config=resource_group_name={rg}",
        f"-backend-config=storage_account_name={storage}",
        f"-backend-config=container_name={container}",
        f"-backend-config=key={state_key}",
        "-backend-config=use_azuread_auth=true",
    ]
    proc_rc, proc_out, proc_err = _run_tf(cmd, workdir, timeout=300)
    marker = workdir / INIT_MARKER
    if proc_rc == 0:
        marker.write_text(state_key)
    else:
        # Make sure a stale marker from a previous successful init does not
        # mislead a subsequent plan into thinking init succeeded this time.
        if marker.exists():
            marker.unlink()
    return {
        "ok": proc_rc == 0,
        "exit_code": proc_rc,
        "stdout_tail": proc_out[-4000:],
        "stderr_tail": proc_err[-2000:],
        "state_key": state_key,
    }


# ---------------------------------------------------------------------------
# terraform_plan


def terraform_plan(session_id: str | None) -> dict[str, Any]:
    workdir = template_dir(session_id)
    if not workdir.exists():
        return {"ok": False, "error": "template not cloned yet"}
    if not (workdir / INIT_MARKER).exists():
        return {
            "ok": False,
            "error": "terraform_init has not completed successfully for this session; call terraform_init before terraform_plan",
        }
    if not (workdir / TFVARS_FILE).exists():
        return {
            "ok": False,
            "error": f"{TFVARS_FILE} missing; call set_tf_variables before terraform_plan",
        }

    ok, err = _ensure_az_cli_login()
    if not ok:
        return {"ok": False, "error": f"az login failed: {err}"}

    cmd = [
        "terraform",
        "plan",
        "-no-color",
        "-input=false",
        f"-var-file={TFVARS_FILE}",
        f"-out={PLAN_FILE}",
    ]
    proc_rc, proc_out, proc_err = _run_tf(cmd, workdir, timeout=600)
    summary = ""
    for line in proc_out.splitlines()[::-1]:
        if "Plan:" in line or "No changes" in line:
            summary = line.strip()
            break
    return {
        "ok": proc_rc == 0,
        "exit_code": proc_rc,
        "summary": summary,
        "stdout_tail": proc_out[-6000:],
        "stderr_tail": proc_err[-2000:],
        "plan_path": str(workdir / PLAN_FILE),
    }


# ---------------------------------------------------------------------------
# terraform_apply (background)


def terraform_apply(session_id: str | None) -> dict[str, Any]:
    workdir = template_dir(session_id)
    if not workdir.exists():
        return {"ok": False, "error": "template not cloned yet"}
    if not (workdir / INIT_MARKER).exists():
        return {
            "ok": False,
            "error": "terraform_init has not completed successfully; call terraform_init then terraform_plan before terraform_apply",
        }
    plan_path = workdir / PLAN_FILE
    if not plan_path.exists():
        return {"ok": False, "error": "no plan file; run terraform_plan first"}

    ok, err = _ensure_az_cli_login()
    if not ok:
        return {"ok": False, "error": f"az login failed: {err}"}

    job_id = uuid.uuid4().hex[:12]
    jdir = jobs_dir(session_id)
    log_path = jdir / f"{job_id}.log"
    exit_path = jdir / f"{job_id}.exit"
    pid_path = jdir / f"{job_id}.pid"

    log_fh = open(log_path, "wb")
    cmd = [
        "terraform",
        "apply",
        "-no-color",
        "-input=false",
        "-auto-approve",
        PLAN_FILE,
    ]

    runner_py = (
        "import os, subprocess, sys\n"
        f"cmd = {cmd!r}\n"
        f"workdir = {str(workdir)!r}\n"
        f"exit_path = {str(exit_path)!r}\n"
        "p = subprocess.run(cmd, cwd=workdir, env=os.environ.copy(), stdout=sys.stdout, stderr=subprocess.STDOUT)\n"
        "open(exit_path, 'w').write(str(p.returncode))\n"
    )
    proc = subprocess.Popen(
        [sys.executable, "-c", runner_py],
        cwd=workdir,
        env=_tf_env(),
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    pid_path.write_text(str(proc.pid))

    return {
        "ok": True,
        "job_id": job_id,
        "log_path": str(log_path),
        "pid": proc.pid,
        "message": "terraform apply started; poll get_deployment_status(job_id).",
    }


# ---------------------------------------------------------------------------
# get_deployment_status


def get_deployment_status(session_id: str | None, job_id: str) -> dict[str, Any]:
    jdir = jobs_dir(session_id)
    log_path = jdir / f"{job_id}.log"
    exit_path = jdir / f"{job_id}.exit"

    if not log_path.exists():
        return {"ok": False, "error": f"unknown job_id {job_id}"}

    log_bytes = log_path.read_bytes()
    tail = log_bytes[-6000:].decode("utf-8", errors="replace")

    if exit_path.exists():
        code = exit_path.read_text().strip()
        try:
            code_int = int(code)
        except ValueError:
            code_int = -1
        terminal = True
        phase = "succeeded" if code_int == 0 else "failed"
        outputs: dict[str, Any] = {}
        if code_int == 0:
            workdir = template_dir(session_id)
            try:
                op = subprocess.run(
                    ["terraform", "output", "-json"],
                    cwd=workdir,
                    env=_tf_env(),
                    capture_output=True,
                    text=True,
                    timeout=60,
                )
                if op.returncode == 0:
                    outputs = json.loads(op.stdout or "{}")
            except Exception:  # noqa: BLE001
                pass
        return {
            "ok": True,
            "job_id": job_id,
            "terminal": terminal,
            "phase": phase,
            "exit_code": code_int,
            "log_tail": tail,
            "log_size": len(log_bytes),
            "outputs": outputs,
        }

    return {
        "ok": True,
        "job_id": job_id,
        "terminal": False,
        "phase": "running",
        "log_tail": tail,
        "log_size": len(log_bytes),
    }


# ---------------------------------------------------------------------------
# workspace_status — let the agent inspect what's already on disk before
# deciding whether to re-run clone/init/plan. Critical after a handback
# from another agent: the workspace from earlier in the conversation is
# usually still there and should be reused, not wiped.


def workspace_status(session_id: str | None) -> dict[str, Any]:
    """Report what artifacts already exist in the per-session workspace.

    Returns a dict with:
      * ``cloned``        — bool, repo present (has ``.git`` dir)
      * ``tfvars_set``    — bool, ``terraform.tfvars.json`` present
      * ``tfvars``        — dict, parsed contents (if present)
      * ``init_done``     — bool, ``terraform init`` completed previously
      * ``plan_present``  — bool, ``tfplan.binary`` exists (plan ran)
      * ``ready_to_apply`` — bool, all of cloned+tfvars+init+plan true
      * ``files``         — top-level files in the workdir (debug aid)
    """
    from .workspace import template_root  # local to avoid cycles

    root = template_root(session_id)
    workdir = template_dir(session_id)
    cloned = (root / ".git").is_dir()
    tfvars_path = workdir / TFVARS_FILE if workdir.exists() else None
    tfvars_set = bool(tfvars_path and tfvars_path.exists())
    tfvars: dict[str, Any] = {}
    if tfvars_set:
        try:
            tfvars = json.loads(tfvars_path.read_text())  # type: ignore[union-attr]
        except Exception:  # noqa: BLE001
            tfvars = {}
    init_done = workdir.exists() and (workdir / INIT_MARKER).exists()
    plan_present = workdir.exists() and (workdir / PLAN_FILE).exists()
    files: list[str] = []
    if workdir.exists():
        try:
            files = sorted(p.name for p in workdir.iterdir() if not p.name.startswith("."))
        except Exception:  # noqa: BLE001
            pass

    return {
        "ok": True,
        "cloned": cloned,
        "tfvars_set": tfvars_set,
        "tfvars": tfvars,
        "init_done": init_done,
        "plan_present": plan_present,
        "ready_to_apply": cloned and tfvars_set and init_done and plan_present,
        "workdir": str(workdir),
        "files": files,
    }
