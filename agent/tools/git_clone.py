"""clone_template_repo tool."""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .workspace import template_root, template_subfolder

DEFAULT_REPO = os.environ.get(
    "TEMPLATE_REPO_URL",
    "https://github.com/anwather/vm-template-repo.git",
)


def clone_template_repo(
    session_id: str | None,
    branch: str | None = None,
    repo_url: str | None = None,
) -> dict[str, Any]:
    """Clone the VM template repo into the per-session workspace.

    Returns the local path and a list of top-level files for context. The
    repo is cloned in full; downstream tools then operate inside the
    ``TEMPLATE_SUBFOLDER`` subdirectory (e.g. ``windows`` or ``linux``).

    Idempotent: if a clone already exists for this session and contains a
    ``.git`` directory, we keep it (along with any ``terraform init`` /
    ``plan`` artifacts) and return ``already_present=True``. This avoids
    accidentally wiping a half-completed deploy when control returns to
    the agent after a handback from another agent.
    """
    target: Path = template_root(session_id)

    if target.exists() and (target / ".git").is_dir():
        sub = template_subfolder()
        workdir = target / sub if sub else target
        if workdir.exists():
            files = sorted(
                p.name for p in workdir.iterdir() if not p.name.startswith(".")
            )
            return {
                "ok": True,
                "path": str(workdir),
                "repo_root": str(target),
                "subfolder": sub or None,
                "branch": branch or "default",
                "files": files,
                "already_present": True,
            }

    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)

    cmd = ["git", "clone", "--depth", "1"]
    if branch:
        cmd += ["--branch", branch]
    cmd += [repo_url or DEFAULT_REPO, str(target)]

    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if proc.returncode != 0:
        return {
            "ok": False,
            "error": proc.stderr.strip() or proc.stdout.strip(),
            "path": str(target),
        }

    sub = template_subfolder()
    workdir = target / sub if sub else target
    if sub and not workdir.exists():
        return {
            "ok": False,
            "error": (
                f"template subfolder {sub!r} not found in cloned repo at {target}; "
                "check TEMPLATE_SUBFOLDER env var matches the repo layout."
            ),
            "path": str(target),
        }

    files = sorted(p.name for p in workdir.iterdir() if not p.name.startswith("."))
    return {
        "ok": True,
        "path": str(workdir),
        "repo_root": str(target),
        "subfolder": sub or None,
        "branch": branch or "default",
        "files": files,
        "already_present": False,
    }

