# vm-hosted-agent

POC: Microsoft Foundry Hosted Agent that conversationally deploys a Windows VM via Terraform.

> Status: under construction. See `C:\Users\anwather\.copilot\session-state\<session>\plan.md` for the implementation plan.

## High-level architecture

```
Browser (HTMX) ──HTTPS/Easy Auth──▶ FastAPI Container App
                                         │
                              Responses API (SSE)
                                         ▼
                          Foundry Hosted Agent (containerized)
                              │ tools: git clone, terraform init/plan/apply,
                              │        generate_admin_password (→ Key Vault)
                              ▼
                          Azure subscription (target VM)
```

## Components

| Path | Purpose |
|---|---|
| `agent/` | Hosted agent container — `azure-ai-agentserver-responses`, terraform binary, git |
| `frontend/` | FastAPI + HTMX chat + tool-call monitor |
| `infra/` | Bicep modules: ACR, tfstate storage, Key Vault, Container App, identity, RBAC |
| `deploy/` | Agent deployment script (`azure-ai-projects` `create_version`) and `agent.yaml` |

## Quickstart (TBD — completed at end of POC)

```pwsh
azd auth login
azd up                           # provisions infra + frontend
python deploy/deploy_agent.py    # builds + pushes agent image, registers version
# open the frontend URL printed by azd
```
