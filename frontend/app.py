"""FastAPI + HTMX frontend for the Task Orchestrator POC.

Three-pane UI: chat, tool-call list, terraform log.
Streams Foundry Responses-API SSE events to the browser.

Multi-agent routing (caller-stack model):
  - User talks to ``ORCHESTRATOR_AGENT_NAME`` first (a Foundry persistent
    agent).
  - Any agent can emit a forward marker
    ``{"__route__":"windows|linux|pricing","summary":"..."}`` in its text
    output. Orchestrator uses it to delegate; specialists may forward to
    the pricing agent for a cost estimate.
  - Specialist or pricing agents can emit a back marker
    ``{"__handback__":"caller","summary":"..."}`` to return control. The
    frontend resolves "caller" from a per-browser caller stack so agents
    don't need to know who called them.
  - Backend detects either marker in text deltas, suppresses it from the
    user-visible stream, and emits a custom ``routing`` SSE event with
    fields ``{direction, target?, summary?}``.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import AsyncIterator

import tiktoken
from azure.identity.aio import DefaultAzureCredential
from openai import AsyncOpenAI
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("vmagent-frontend")

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]

# Back-compat: HOSTED_AGENT_NAME is the legacy single-agent env var.
# It is treated as the Windows hosted agent name when the new
# HOSTED_AGENT_NAME_WINDOWS isn't set.
_LEGACY_HOSTED = os.environ.get("HOSTED_AGENT_NAME", "vmagent-agent-windows")
HOSTED_AGENT_NAME_WINDOWS = os.environ.get("HOSTED_AGENT_NAME_WINDOWS", _LEGACY_HOSTED)
HOSTED_AGENT_NAME_LINUX = os.environ.get("HOSTED_AGENT_NAME_LINUX", "vmagent-agent-linux")
HOSTED_AGENT_NAME_PRICING = os.environ.get(
    "HOSTED_AGENT_NAME_PRICING", "vmagent-agent-pricing"
)
ORCHESTRATOR_AGENT_NAME = os.environ.get("ORCHESTRATOR_AGENT_NAME", "taskorch-orchestrator")
HOSTED_AGENT_VERSION = os.environ.get("HOSTED_AGENT_VERSION", "1")
FRONTEND_VERSION = os.environ.get("FRONTEND_VERSION", "dev")

# Maps the short label used in routing markers to the actual agent name the
# browser/backend will talk to next.
ROUTE_TARGETS: dict[str, str] = {
    "windows": HOSTED_AGENT_NAME_WINDOWS,
    "linux": HOSTED_AGENT_NAME_LINUX,
    "pricing": HOSTED_AGENT_NAME_PRICING,
}

# Whitelist of valid agent targets the browser may request via /chat
ALLOWED_AGENTS: set[str] = {
    ORCHESTRATOR_AGENT_NAME,
    HOSTED_AGENT_NAME_WINDOWS,
    HOSTED_AGENT_NAME_LINUX,
    HOSTED_AGENT_NAME_PRICING,
}

app = FastAPI(title="task-orchestrator frontend")

BASE_DIR = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")

# Lazily-created singletons.
_credential: DefaultAzureCredential | None = None
# One AsyncOpenAI client per agent name (each has a different base URL).
_openai_clients: dict[str, AsyncOpenAI] = {}

AAD_SCOPE = "https://ai.azure.com/.default"

# Routing markers. Forward marker is emitted by the orchestrator (to delegate
# to a specialist) or by a specialist (to call pricing). Back marker is
# emitted by a specialist or pricing agent to return control to whoever
# called them. Both markers tolerate optional whitespace and an optional
# ``summary`` field whose value may contain backslash-escaped quotes.
ROUTE_MARKER_RE = re.compile(
    r'\{\s*"__route__"\s*:\s*"(?P<route>windows|linux|pricing)"'
    r'(?:\s*,\s*"summary"\s*:\s*"(?P<rsum>(?:\\.|[^"\\\n])*)")?\s*\}'
)
HANDBACK_MARKER_RE = re.compile(
    r'\{\s*"__handback__"\s*:\s*"caller"'
    r'(?:\s*,\s*"summary"\s*:\s*"(?P<hsum>(?:\\.|[^"\\\n])*)")?\s*\}'
)


def _agent_base_url(agent_name: str) -> str:
    return f"{PROJECT_ENDPOINT.rstrip('/')}/agents/{agent_name}/endpoint/protocols/openai"


def _get_credential() -> DefaultAzureCredential:
    global _credential
    if _credential is None:
        _credential = DefaultAzureCredential()
    return _credential


def _openai(agent_name: str) -> AsyncOpenAI:
    """Return (creating if needed) an AsyncOpenAI client for the given agent."""
    client = _openai_clients.get(agent_name)
    if client is not None:
        return client

    cred = _get_credential()
    import httpx

    class _BearerAuth(httpx.Auth):
        requires_request_body = False

        async def async_auth_flow(self, request):
            token = await cred.get_token(AAD_SCOPE)
            request.headers["Authorization"] = f"Bearer {token.token}"
            yield request

    http_client = httpx.AsyncClient(auth=_BearerAuth(), timeout=httpx.Timeout(120.0, read=600.0))
    client = AsyncOpenAI(
        base_url=_agent_base_url(agent_name),
        api_key="placeholder-replaced-by-bearer-auth",
        http_client=http_client,
        default_query={"api-version": "v1"},
        default_headers={"Foundry-Features": "HostedAgents=V1Preview"},
    )
    _openai_clients[agent_name] = client
    return client


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    user = request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME", "anonymous")
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "user": user,
            "orchestrator_agent_name": ORCHESTRATOR_AGENT_NAME,
            "hosted_agent_name_windows": HOSTED_AGENT_NAME_WINDOWS,
            "hosted_agent_name_linux": HOSTED_AGENT_NAME_LINUX,
            "hosted_agent_name_pricing": HOSTED_AGENT_NAME_PRICING,
            "agent_version": HOSTED_AGENT_VERSION,
            "frontend_version": FRONTEND_VERSION,
        },
    )


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


def _sse(event_type: str, data) -> bytes:
    payload = data if isinstance(data, str) else json.dumps(data, default=str)
    return f"event: {event_type}\ndata: {payload}\n\n".encode("utf-8")


_USAGE_KEYS = {"input_tokens", "output_tokens", "total_tokens", "prompt_tokens", "completion_tokens"}


# tiktoken encoding for the gpt-5 / gpt-4o family. Foundry hosted agents on
# gpt-5.1 use the o200k_base tokenizer; if unavailable, fall back to cl100k.
def _get_encoding() -> tiktoken.Encoding:
    try:
        return tiktoken.get_encoding("o200k_base")
    except Exception:
        return tiktoken.get_encoding("cl100k_base")


_encoding: tiktoken.Encoding | None = None


def _enc() -> tiktoken.Encoding:
    global _encoding
    if _encoding is None:
        _encoding = _get_encoding()
    return _encoding


def _count_tokens(text: str) -> int:
    if not text:
        return 0
    try:
        return len(_enc().encode(text, disallowed_special=()))
    except Exception:
        return max(1, len(text) // 4)


def _count_input_tokens(input_list: list) -> int:
    """Estimate prompt tokens. Includes a small per-message overhead for role
    framing, matching OpenAI's published heuristic (~4 tokens/message)."""
    total = 0
    for turn in input_list:
        content = turn.get("content")
        if isinstance(content, list):
            # Multi-part content (rare here); concatenate text parts.
            content = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        total += _count_tokens(str(content or ""))
        total += 4  # role + delimiters
    total += 2  # priming tokens
    return total


def _find_usage(obj, depth: int = 0):
    """Recursively search a payload for a token-usage dict."""
    if obj is None or depth > 5:
        return None
    if isinstance(obj, dict):
        u = obj.get("usage")
        if isinstance(u, dict) and _USAGE_KEYS & set(u.keys()):
            return u
        for v in obj.values():
            found = _find_usage(v, depth + 1)
            if found:
                return found
    elif isinstance(obj, list):
        for v in obj:
            found = _find_usage(v, depth + 1)
            if found:
                return found
    return None


async def _stream_responses(
    message: str,
    history: list | None,
    agent_name: str,
) -> AsyncIterator[bytes]:
    """Call the chosen Foundry agent via the Responses-API endpoint and
    forward every chunk to the browser as SSE.

    Intercepts both routing markers in text deltas:
      * forward ``{"__route__": "windows|linux|pricing", "summary": "..."}``
      * back    ``{"__handback__": "caller", "summary": "..."}``

    Drops the marker from the user-visible stream and emits a custom
    ``routing`` SSE event with fields ``{direction, target?, summary?}``.
    Buffering applies to every agent — any of them may emit a marker.
    """
    openai_client = _openai(agent_name)

    input_list: list = []
    if history:
        for turn in history:
            role = turn.get("role")
            content = turn.get("content")
            if role in ("user", "assistant") and content:
                input_list.append({"role": role, "content": content})
    input_list.append({"role": "user", "content": message})

    try:
        stream = await openai_client.responses.create(
            input=input_list,
            stream=True,
            store=False,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("responses.create failed (agent=%s)", agent_name)
        yield _sse("error", {"message": str(exc)})
        yield _sse("done", {})
        return

    last_usage = None
    estimated_input = _count_input_tokens(input_list)
    output_text_buf: list[str] = []

    # Buffer that holds back the tail of pending text deltas so we never
    # emit a partially-formed marker. We only need to suppress one marker
    # per response — once detected, we stop scanning and pass through.
    pending_text = ""
    routing_emitted = False

    def _split_safe(buf: str) -> tuple[str, str]:
        """Split ``buf`` so we never emit a partial marker.

        Hold back from the last ``{`` onward; that's the earliest position
        either marker (``__route__`` or ``__handback__``) could start.
        """
        idx = buf.rfind("{")
        if idx < 0:
            return buf, ""
        return buf[:idx], buf[idx:]

    def _scan_marker(buf: str):
        """Return (kind, match) for the first marker in ``buf`` or None."""
        m_route = ROUTE_MARKER_RE.search(buf)
        m_back = HANDBACK_MARKER_RE.search(buf)
        if m_route and m_back:
            return ("route", m_route) if m_route.start() <= m_back.start() else ("handback", m_back)
        if m_route:
            return ("route", m_route)
        if m_back:
            return ("handback", m_back)
        return None

    try:
        async for event in stream:
            try:
                event_type = getattr(event, "type", "event")
                payload = event.model_dump() if hasattr(event, "model_dump") else dict(event)
            except Exception:
                event_type = "event"
                payload = {"raw": str(event)}
            usage = _find_usage(payload)
            if usage:
                last_usage = usage
            # Capture text deltas + function-call argument deltas for an
            # output-token estimate when Foundry doesn't report usage.
            if event_type == "response.output_text.delta":
                d = payload.get("delta") or payload.get("text") or ""
                if d:
                    output_text_buf.append(d)
                if not routing_emitted and d:
                    pending_text += d
                    found = _scan_marker(pending_text)
                    if found:
                        kind, m = found
                        before = pending_text[: m.start()]
                        after = pending_text[m.end():]
                        # Drop one immediately-trailing newline from the
                        # marker line so the user-visible output looks clean.
                        if after.startswith("\n"):
                            after = after[1:]
                        if before:
                            yield _sse(event_type, {**payload, "delta": before})
                        if kind == "route":
                            target = m.group("route")
                            summary = m.group("rsum") or ""
                            logger.info(
                                "routing forward agent=%s target=%s summary=%s",
                                agent_name, target, summary,
                            )
                            yield _sse("routing", {
                                "direction": "forward",
                                "target": target,
                                "summary": summary,
                            })
                        else:
                            summary = m.group("hsum") or ""
                            logger.info(
                                "routing handback agent=%s summary=%s",
                                agent_name, summary,
                            )
                            yield _sse("routing", {
                                "direction": "back",
                                "summary": summary,
                            })
                        routing_emitted = True
                        pending_text = ""
                        if after:
                            yield _sse(event_type, {**payload, "delta": after})
                        continue
                    # No marker yet — flush everything up to the last '{'
                    # and hold the tail in case it grows into a marker.
                    safe, pending_text = _split_safe(pending_text)
                    if safe:
                        yield _sse(event_type, {**payload, "delta": safe})
                    continue
            elif event_type == "response.function_call_arguments.delta":
                d = payload.get("delta") or ""
                if d:
                    output_text_buf.append(d)
            elif event_type == "response.output_item.done":
                item = payload.get("item") or {}
                if item.get("type") == "function_call":
                    args = item.get("arguments")
                    if isinstance(args, str):
                        output_text_buf.append(args)
            elif event_type in ("response.completed", "response.done"):
                # Stream finished — flush any held-back tail.
                if pending_text:
                    yield _sse(
                        "response.output_text.delta",
                        {"delta": pending_text},
                    )
                    pending_text = ""
            yield _sse(event_type, payload)
    except Exception as exc:  # noqa: BLE001
        logger.exception("stream iteration failed")
        yield _sse("error", {"message": str(exc)})
    finally:
        # Final safety flush: in case the stream ended without a completed
        # event (error path), emit any remaining tail so the user isn't
        # silently truncated.
        if pending_text:
            yield _sse(
                "response.output_text.delta", {"delta": pending_text}
            )
            pending_text = ""
        if last_usage:
            logger.info("stream usage (provider) agent=%s: %s", agent_name, last_usage)
            yield _sse("usage", last_usage)
        else:
            estimated_output = _count_tokens("".join(output_text_buf))
            est = {
                "input_tokens": estimated_input,
                "output_tokens": estimated_output,
                "total_tokens": estimated_input + estimated_output,
                "estimated": True,
            }
            logger.info("stream usage (estimated) agent=%s: %s", agent_name, est)
            yield _sse("usage", est)
        yield _sse("done", {})


@app.post("/chat")
async def chat(request: Request) -> StreamingResponse:
    body = await request.json()
    message: str = (body or {}).get("message", "").strip()
    history = (body or {}).get("history") or []
    if not isinstance(history, list):
        history = []
    requested_agent = (body or {}).get("agent") or ORCHESTRATOR_AGENT_NAME
    if requested_agent not in ALLOWED_AGENTS:
        return StreamingResponse(
            iter([
                _sse("error", {"message": f"unknown agent {requested_agent!r}"}),
                _sse("done", {}),
            ]),
            media_type="text/event-stream",
        )
    if not message:
        return StreamingResponse(
            iter([_sse("error", {"message": "empty message"}), _sse("done", {})]),
            media_type="text/event-stream",
        )
    return StreamingResponse(
        _stream_responses(message, history, requested_agent),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
