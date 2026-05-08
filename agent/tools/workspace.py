"""Per-session workspace helpers.

Hosted agent containers expose a writable `/files` directory; per documentation
this is intended to be used for session-scoped state. We layer a per-session
sub-directory under it so that concurrent conversations don't trample each
other's terraform working directory.

The same container image serves both the Windows and Linux VM-builder hosted
agents. The repo cloned by ``clone_template_repo`` contains both ``windows/``
and ``linux/`` Terraform module subfolders; ``TEMPLATE_SUBFOLDER`` selects
which one downstream tools (init/plan/apply, set_tf_variables) operate inside.
"""
from __future__ import annotations

import os
import re
from pathlib import Path

WORKSPACE_ROOT = Path(os.environ.get("AGENT_WORKSPACE_ROOT", "/files"))


def _safe(component: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]", "_", component or "default")[:64]


def session_dir(session_id: str | None) -> Path:
    """Return (and create) the working directory for a given session."""
    sid = _safe(session_id or "default")
    path = WORKSPACE_ROOT / sid
    path.mkdir(parents=True, exist_ok=True)
    return path


def template_root(session_id: str | None) -> Path:
    """The repo clone root (`<session>/template`)."""
    return session_dir(session_id) / "template"


def template_subfolder() -> str:
    """Subfolder of the cloned template repo to operate inside.

    Empty string means the repo root itself (back-compat with the original
    template that had no subfolders).
    """
    sub = (os.environ.get("TEMPLATE_SUBFOLDER") or "").strip().strip("/\\")
    return sub


def template_dir(session_id: str | None) -> Path:
    """Working directory for terraform commands.

    If ``TEMPLATE_SUBFOLDER`` env var is set we drill into it; otherwise we
    return the repo root for back-compat with the original (un-foldered)
    template.
    """
    root = template_root(session_id)
    sub = template_subfolder()
    return (root / sub) if sub else root


def jobs_dir(session_id: str | None) -> Path:
    p = session_dir(session_id) / "jobs"
    p.mkdir(parents=True, exist_ok=True)
    return p

