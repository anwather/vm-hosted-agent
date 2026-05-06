"""FastAPI + HTMX frontend for the vm-hosted-agent POC.

Three-pane UI: chat, tool-call list, terraform log.
SSE relay: streams Foundry Responses-API events to the browser.

Filled in by frontend-sse-relay and frontend-ui todos.
"""
from __future__ import annotations

import os

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

app = FastAPI(title="vm-hosted-agent frontend")

BASE_DIR = os.path.dirname(__file__)
templates = Jinja2Templates(directory=os.path.join(BASE_DIR, "templates"))
app.mount("/static", StaticFiles(directory=os.path.join(BASE_DIR, "static")), name="static")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    user = request.headers.get("X-MS-CLIENT-PRINCIPAL-NAME", "anonymous")
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "user": user,
            "agent_name": os.getenv("HOSTED_AGENT_NAME", "vmagent-agent"),
        },
    )


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


# /chat SSE relay added in frontend-sse-relay todo.
