# Task Orchestrator

A Microsoft Foundry **multi-agent orchestration** demo:

* **Orchestrator** (Foundry persistent agent) — talks to the user, decides
  whether they want a Windows or Linux VM, then hands off.
* **Windows VM agent** (Foundry **hosted** agent, containerized) — collects
  parameters and runs Terraform.
* **Linux VM agent** (Foundry hosted agent, **same container image**, different
  env vars + system prompt + template subfolder) — same flow for Linux.
* **Frontend** (FastAPI + HTMX, Container App, Easy Auth) — single chat
  surface; transparently re-targets the SSE stream when the orchestrator emits
  a routing marker.

> Folder name stays `vm-hosted-agent` for git history; live resource names use
> the `vmagent-` prefix; the user-facing project name is **Task Orchestrator**.

## Architecture

```
Browser (HTMX, SSE)
   │
   ▼
Container App: vmagent-frontend  (FastAPI, Easy Auth)
   │
   ▼  Responses API stream (per-agent OpenAI client)
   │
   │  (1) user always talks to ORCHESTRATOR first
   ▼
Foundry persistent agent: taskorch-orchestrator  (PromptAgentDefinition)
   │   System prompt forces emission of:
   │       {"__route__": "windows"}    or    {"__route__": "linux"}
   │   on a line by itself BEFORE any other text.
   │
Frontend SSE proxy
   │   Detects marker mid-stream → suppresses the marker line →
   │   emits a `routing` event → swaps active agent → resets thread →
   │   replays user's original message to the chosen specialist.
   │
   ├──►  vmagent-agent          (hosted, role=vm-builder, OS=windows, tpl=windows/)
   ├──►  vmagent-agent-linux    (hosted, **same image**,  role=vm-builder, OS=linux, tpl=linux/)
   └──►  vmagent-agent-pricing  (hosted, **same image**,  role=pricing — VM monthly cost in AUD)

Caller-stack (browser-side):
* Forward marker: {"__route__":"<windows|linux|pricing>","summary":"<optional>"}
* Back marker:    {"__handback__":"caller","summary":"<short>"}
* Specialists may forward to pricing for an estimate; pricing always hands back
  to its caller. Specialists hand back to orchestrator on user intent change
  or terminal terraform result.

Foundry env-var prefix reservations: AGENT_*, FOUNDRY_*, APPLICATIONINSIGHTS_*
are rejected. We use VM_OS_FAMILY (instead of AGENT_OS) and VM_AGENT_ROLE
(instead of AGENT_ROLE).
```

## Components

| Path | Purpose |
|---|---|
| `agent/` | Hosted-agent container. `azure-ai-agentserver-responses`, terraform binary, git. OS-parameterized via env vars. |
| `frontend/` | FastAPI + HTMX chat. Multi-agent dispatcher with marker-based handoff. |
| `infra/` | Bicep: ACR, Key Vault, tfstate Storage (AAD-auth), Container Apps env + frontend app, UAMI. |
| `deploy/deploy_agent.py` | Deploys ONE hosted agent (`--target windows` or `--target linux`). |
| `deploy/deploy_orchestrator.py` | Deploys/updates the persistent orchestrator agent. |
| `deploy/assign_rbac.py` | Assigns the post-deploy RBAC roles to a hosted agent's per-version managed identity. |
| `deploy/deploy_all.py` | One-shot: builds image, deploys both hosted agents + orchestrator, runs RBAC. |

External: VM templates live at <https://github.com/anwather/vm-template-repo>
with subfolders `windows/` and `linux/`.

## Pre-requisites (read before you deploy)

### Subscriptions & resource groups

* **Target subscription** — where VMs will be built. The deployer needs
  Owner-equivalent rights here so RBAC role assignments succeed.
* **Foundry-hosting subscription** — where the Foundry account/project lives.
  Can be the same subscription; if different, you must be logged in as a
  principal with Contributor on the Foundry resource group as well.
* One **resource group** for the demo infra (this README uses
  `multi-agent-demo`). All Bicep resources land here.

### Azure tenant / Entra ID requirements

* Tenant role **Application Administrator** (or Cloud Application
  Administrator / Global Administrator) on the deployer account — required
  to create the Entra App Registration used for Easy Auth in step 5.
* Tenant role **User Access Administrator** (or Owner) at the target
  subscription — required for `assign_rbac.py` to grant the hosted agent's
  managed identity Contributor + data-plane roles. `Contributor` alone is
  NOT enough to assign roles to others.
* You must be able to **consent to delegated User.Read** for the Entra app
  (default admin consent on a single-tenant app is automatic; multi-tenant
  setups need explicit admin consent).

### Foundry account, project, capability host

* A **Foundry account + project** (the demo uses region `australiaeast`).
  Any region is supported as long as the model below is available there.
* Model deployment **`gpt-5.1`** in that project (deployment name *exactly*
  `gpt-5.1`; rename in the prompt files if you use a different name).
* A **capability host** must exist on the Foundry CognitiveServices account
  before hosted agents can be created. Provision it via the Foundry portal
  (**Project → Settings → Capability hosts → Add → "HostedAgents-V1Preview"**)
  or with the `azureaifoundry` CLI extension. Without this, the first
  `deploy_agent.py` call returns `400: capability host not found`.
* The Foundry account must allow outbound to ACR (default allow-all is fine)
  so it can pull the agent image.

### Tooling on the deployer machine

* **Azure CLI ≥ 2.60** (`az login` with the right account). Container Apps
  and Foundry use newer commands than older CLI versions.
* **Python ≥ 3.11** with `python -m pip install -r requirements-deploy.txt`.
* **PowerShell 7+** if you use `deploy/build_and_push.ps1` (works on
  Linux/macOS too via `pwsh`).
* No Docker required — image builds run in ACR Tasks (`az acr build`).

### Network & policy

* No private endpoints in this demo — ACR, KV, and tfstate Storage are all
  public-endpoint with AAD-only auth. If your tenant policy requires PEs,
  you'll need to extend the Bicep with PE modules and ensure the Foundry
  hosted-agent egress can reach them.
* Shared-key access on Storage is **disabled** (`allowSharedKeyAccess: false`);
  the Terraform backend uses AAD auth via the agent's MI.

## Quickstart (clean RG, end-to-end)

Replace placeholders (`<...>`) with your values. Image versions shown
(`0.4.3`) match the current main branch — bump as you publish new tags.

```powershell
# 0) One-time: install deploy-script dependencies
python -m pip install -r requirements-deploy.txt
az login
az account set --subscription <TARGET_SUB_ID>

# 1) Provision infra
az group create -n multi-agent-demo -l australiaeast
az deployment group create `
  -g multi-agent-demo `
  -f infra/main.bicep `
  -p targetSubscriptionId=<TARGET_SUB_ID> `
     foundryProjectEndpoint=https://<FOUNDRY_ACCT>.services.ai.azure.com/api/projects/<PROJECT>

# Capture outputs you'll reuse below
$out = az deployment group show -g multi-agent-demo -n main --query properties.outputs -o json | ConvertFrom-Json
$ACR   = $out.AZURE_CONTAINER_REGISTRY_NAME.value
$KVURI = $out.KEYVAULT_URI.value
$STG   = $out.TFSTATE_STORAGE_ACCOUNT_NAME.value
$FQDN  = $out.FRONTEND_FQDN.value

# 2) Build the agent + frontend images.
#    az acr build streaming logs can crash on Windows with a cp1252
#    UnicodeEncodeError — pass --no-logs and force UTF-8 console encoding.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
az acr build --registry $ACR --image vmagent-agent:0.4.3    --file agent/Dockerfile    agent    --no-logs
az acr build --registry $ACR --image vmagent-frontend:0.4.3 --file frontend/Dockerfile frontend --no-logs
#  (Convenience wrapper for the agent image: .\deploy\build_and_push.ps1 -Registry $ACR -Tag 0.4.3)

# 3) Deploy orchestrator + 3 hosted agents + RBAC in one shot
$env:FOUNDRY_PROJECT_ENDPOINT      = "https://<FOUNDRY_ACCT>.services.ai.azure.com/api/projects/<PROJECT>"
$env:CONTAINER_IMAGE               = "$ACR.azurecr.io/vmagent-agent:0.4.3"
$env:TFSTATE_STORAGE_ACCOUNT_NAME  = $STG
$env:TFSTATE_RESOURCE_GROUP        = "multi-agent-demo"
$env:KEYVAULT_URI                  = $KVURI
$env:KEYVAULT_NAME                 = ($KVURI -replace 'https://','' -replace '\.vault\.azure\.net/?$','')
$env:VM_TARGET_SUBSCRIPTION_ID     = "<TARGET_SUB_ID>"
$env:FOUNDRY_RG                    = "<FOUNDRY_RG>"
$env:FOUNDRY_ACCOUNT_NAME          = "<FOUNDRY_ACCT>"
$env:FOUNDRY_PROJECT_NAME          = "<PROJECT>"
python deploy/deploy_all.py
# Expect "=== deploy_all complete ===" at the end. Three hosted agents
# (windows, linux, pricing) plus the orchestrator are now ACTIVE.

# 4) Update the frontend container app with the new image + version label
az containerapp update -n vmagent-frontend -g multi-agent-demo `
  --image "$ACR.azurecr.io/vmagent-frontend:0.4.3" `
  --set-env-vars FRONTEND_VERSION=0.4.3 `
                 ORCHESTRATOR_AGENT_NAME=taskorch-orchestrator `
                 HOSTED_AGENT_NAME_WINDOWS=vmagent-agent `
                 HOSTED_AGENT_NAME_LINUX=vmagent-agent-linux `
                 HOSTED_AGENT_NAME_PRICING=vmagent-agent-pricing

# 5) Easy Auth (Entra) on the frontend — one-time, needs App Admin role
$appId = az ad app create --display-name "Task Orchestrator" `
  --web-redirect-uris "https://$FQDN/.auth/login/aad/callback" `
  --query appId -o tsv
$secret = az ad app credential reset --id $appId --years 1 --query password -o tsv
az containerapp auth microsoft update -n vmagent-frontend -g multi-agent-demo `
  --client-id $appId --client-secret $secret `
  --tenant-id (az account show --query tenantId -o tsv) --yes
az containerapp auth update -n vmagent-frontend -g multi-agent-demo `
  --enabled true --action RedirectToLoginPage --redirect-provider azureactivedirectory
```

Browse to `https://$FQDN`. Sign in. Type `I want a Windows VM` (or Linux).
You should see the orchestrator's brief reply, a `Handed off to <agent>.`
system bubble, then the specialist starts asking VM parameter questions.

### Re-deploys (image bump only)

After editing the agent code or prompts:

```powershell
.\deploy\build_and_push.ps1 -Registry $ACR -Tag 0.4.4   # publish a new tag
$env:CONTAINER_IMAGE = "$ACR.azurecr.io/vmagent-agent:0.4.4"
python deploy/deploy_all.py                              # new versions of all 3 hosted agents + RBAC
```

Frontend bumps follow the same pattern with `az acr build` +
`az containerapp update` (step 2 + step 4 above) — no Foundry call needed.

## How handoff works (the routing-signal pattern)

Server-side connected agents (ConnectedAgentTool, A2A, OpenAPI tool) all turn
out to be dead-ends or fragile when the **target** is a hosted agent — the
SDK requires persistent-agent IDs (which hosted agents don't have), and
OpenAPI/Function tools can't inject the required `Foundry-Features` header
or resolve in pass-through SSE.

Instead, **the frontend is the dispatcher**:

1. The orchestrator's system prompt forces it to emit
   `{"__route__":"windows"}` or `{"__route__":"linux"}` on a line by itself.
2. `frontend/app.py::_stream_responses` watches orchestrator text deltas,
   buffers any partial tail starting at `{`, and on regex match:
   * Suppresses the marker line from the visible stream.
   * Emits a custom SSE `routing` event with `{"target": "...", "agent_name": "..."}`.
3. `frontend/static/app.js` captures `routing` mid-stream, then on the
   stream's `done` event:
   * Sets `activeAgent` to the chosen specialist.
   * **Resets the conversation** (the hosted agent should not see the
     orchestrator's own chatter).
   * Inserts a `Handed off to <agent>.` system bubble.
   * Auto-replays the user's original message to the new agent.

Subsequent messages go directly to the specialist (no second handoff).

### Specialist → orchestrator handback + Pricing agent (Phase J)

The same marker mechanism powers two extra flows:

* **Handback to caller** — any specialist (or pricing) can emit
  `{"__handback__":"caller","summary":"<short>"}`. The frontend keeps a
  `callerStack`; on handback it pops the stack, switches `activeAgent` back
  to the caller, and injects a synthetic assistant turn
  `[handback note: <summary>]` into the caller's history (visible to the
  LLM, hidden from the user UI). The caller resumes its conversation.
* **Forward to pricing** — Win/Linux specialists may forward to
  `vmagent-agent-pricing` with `{"__route__":"pricing","summary":"..."}`
  carrying VM context (OS, region, SKU). The pricing agent always answers
  cost questions only and hands back when done. Pricing conversation is
  reset on each call (cost questions are self-contained).

Cycle prevention rules (encoded in prompts + frontend rejection of unknown
forward targets):
* Orchestrator may forward to windows/linux only.
* Specialists may forward to pricing only (never to each other).
* Pricing may only hand back, never forward.

A **Start over** button in the header clears all state (conversations Map,
callerStack, tokens, banners) and reposts the orchestrator greeting.

#### Pricing tool implementation note (REST-direct, not MCP)

The plan called for spawning `npx @azure/mcp` as a stdio subprocess inside
the agent container to query Azure pricing. We shipped a **direct REST
call** to `https://prices.azure.com/api/retail/prices` instead — same
upstream as the MCP server, no auth needed for retail prices, no subprocess
or cold-start overhead. The MCP packages (`nodejs` + `@azure/mcp` global)
remain installed in the image (Dockerfile) so a future swap to the MCP path
is trivial. The tool returns `{ monthly_aud, hourly_aud, source }` for
`get_vm_monthly_cost(vm_size, region, os_type)`, computing
`monthly = hourly × 730`. **Compute-only** — disk, bandwidth, backups not
included.

#### Agent role wiring

Same image, three behaviors selected by env:

| env var | windows | linux | pricing |
|---|---|---|---|
| `VM_AGENT_ROLE` | `vm-builder` | `vm-builder` | `pricing` |
| `VM_OS_FAMILY` | `windows` | `linux` | (unset) |
| `SYSTEM_PROMPT_FILE` | `system_prompt_windows.txt` | `system_prompt_linux.txt` | `system_prompt_pricing.txt` |
| Tools loaded | `ALL_TOOLS` (git+terraform+kv) | `ALL_TOOLS` | `PRICING_TOOLS` (cost only) |
| RBAC | Contributor + Storage Blob + KV Secrets + AI User + Cog OpenAI User | same | AI User + Cog OpenAI User only |

`deploy/deploy_agent.py::_build_env()` skips terraform/KV/sub vars when
`role=pricing`. `deploy/assign_rbac.py --target pricing` skips the three
vm-builder-only roles.

## Captured fixes (runbook)

These are non-obvious things that broke during initial bring-up. They are all
already encoded in the code/Bicep — listed here so a future reader knows why.

### Foundry / agent SDK

* **Reserved env-var prefixes.** Foundry rejects any `AGENT_*` or `FOUNDRY_*`
  custom env var on a hosted agent. Renamed `AGENT_OS` → `VM_OS_FAMILY`.
* **`Foundry-Features: HostedAgents=V1Preview` header is required** on every
  Responses call to a hosted agent. The frontend sets it via
  `default_headers` on the OpenAI client.
* **`https://ai.azure.com/.default` scope** for the bearer token (not
  `cognitiveservices`).
* **`store=False` is required** when calling Responses against a hosted
  agent — otherwise you get `server_error`.
* **`api-version=v1` must be on the URL.** Set via `default_query` on the
  OpenAI client.
* **URL pattern** for both hosted and persistent agents:
  `{project_endpoint}/agents/{agent_name}/endpoint/protocols/openai`.
* **`instance_identity` (not `identity`)** is where the per-version managed
  identity's `principal_id` lives in `get_version()` output. Each new agent
  *version* gets a NEW MI, so RBAC must be re-run on every new version.
* **Capability host** must exist on the Foundry CognitiveServices account
  before you can create hosted agents. Done via the Foundry portal or
  `azureaifoundry` CLI extension.

### RBAC the hosted agent needs (`assign_rbac.py`)

Run for **every** new hosted-agent version's `principal_id`:

| Role | Scope |
|---|---|
| Contributor                       | Target subscription |
| Storage Blob Data Contributor     | tfstate storage account |
| Key Vault Secrets Officer         | Key Vault |
| Azure AI User                     | Foundry **project** |
| Cognitive Services OpenAI User    | Foundry **account** |

### Terraform / state

* **Storage backend uses AAD auth** (`use_azuread_auth = true`,
  `ARM_USE_CLI = true`) — no shared key. Storage account thus needs:
  * `allowSharedKeyAccess: false`
  * Public network access enabled (or private endpoint) — agent needs
    network reach to the blob endpoint to read/write state.
* **State key format** is `<sub>.<rg>.<vm_name>.tfstate` (in
  `agent/tools/terraform.py`) — gives a stable, human-readable, conflict-free
  key per VM.
* **`init` must run before `plan`** — enforced by `terraform.py` (plan
  refuses to run if no `.terraform/` directory exists in the workdir).
* **Workspace persistence across handbacks (Phase L).** A specialist's
  workspace at `/files/default/<vm_name>/` is preserved across handbacks to
  pricing and back so the existing `terraform init`/`plan` artifacts can be
  reused. Two pieces make this safe:
  * `clone_template_repo` is **idempotent** — if `.git` already exists it
    skips the wipe + clone and returns `already_present=True`.
  * A `workspace_status(session_id)` tool reports `cloned`, `tfvars_set`,
    `init_done`, `plan_present`, and `ready_to_apply`. The Linux/Windows
    prompts instruct the agent to call `workspace_status()` first when
    resuming after a handback and skip straight to `terraform_apply()` when
    `ready_to_apply=true`.
  * Caveat: state lives on the container instance's writable layer. A
    container **restart** (cold start, scale-to-zero, new agent version)
    drops the workspace; the agent will re-clone, re-init, re-plan.

### Frontend

* **`az login --identity` once per process** when running locally with
  managed identity emulation; subsequent token refreshes use the cached
  credential. (Production uses pure `DefaultAzureCredential` chain.)
* **Starlette `TemplateResponse(request, ...)`** — the new positional
  argument; old `(name, {...})` shape was deprecated.
* **`tiktoken` for usage estimation** when the Responses API doesn't return a
  `usage` payload (some hosted-agent variants don't). The token counter
  prefers reported usage when present and falls back to `tiktoken` otherwise.

### Easy Auth pitfall

When the redirect URI on the Entra app registration doesn't exactly match
`https://<fqdn>/.auth/login/aad/callback` you get a generic "page isn't
working" error after sign-in — fix by re-saving the URI on the app
registration.

### Handback prompt rules (Phase J/K)

The handback marker is just a JSON line — making the receiving agent
*behave* correctly required tightening prompts:

* **Pricing → caller summary must include the quote.** `system_prompt_pricing.txt`
  case-2 handback summary requires the most recent
  `SKU/OS/region/AUD/month` figure so the calling specialist knows pricing
  is complete (vs. still pending).
* **Specialists never wait for pricing after handback.**
  `system_prompt_linux.txt` and `system_prompt_windows.txt` both contain an
  explicit rule: receiving a handback FROM pricing means pricing is DONE;
  never reply "I'll wait for the pricing result". Resume the build flow.
* **Orchestrator greets after handback.** When a `[handback note: ...]`
  arrives the orchestrator must read the summary, acknowledge it briefly,
  and either route again or continue the conversation — never go silent.
* **Markdown rendering.** The frontend renders the assistant stream
  incrementally with a markdown parser; partial fences/asterisks are
  rendered visibly during stream and reflowed on `done`. Prompts ask agents
  to keep replies short and avoid heavy formatting mid-stream.

## Repo layout

```
agent/                     OS-parameterized hosted-agent container
  Dockerfile
  main.py                  Reads SYSTEM_PROMPT_FILE, ALLOWED_OS_IMAGES_JSON
  system_prompt_windows.txt
  system_prompt_linux.txt
  system_prompt_pricing.txt
  tools/
    git_clone.py           Honors TEMPLATE_SUBFOLDER; idempotent (skip if .git exists)
    terraform.py           init→plan→apply with state-key derivation; workspace_status() inspector
    workspace.py           Workspace path resolution per subfolder
    keyvault.py            Random admin password to KV
    registry.py            Tool registration; ALL_TOOLS for vm-builder, PRICING_TOOLS for pricing

frontend/                  FastAPI + HTMX, multi-agent dispatcher
  app.py                   Per-agent OpenAI clients; marker detection
  static/app.js            Routing event handler; auto-replay on handoff
  templates/index.html     Header data-attrs feed JS

deploy/
  deploy_agent.py          Deploys one hosted agent (--target windows|linux)
  deploy_orchestrator.py   Deploys/updates the persistent orchestrator
  assign_rbac.py           Post-deploy RBAC for a hosted agent's MI
  deploy_all.py            Orchestrates all of the above

infra/                     Bicep
  main.bicep
  modules/
    acr.bicep
    keyvault.bicep
    storage-tfstate.bicep
    identity.bicep
    rbac-acrpull.bicep
    rbac.bicep
    containerapp-frontend.bicep
```

## Operating notes

* **Adding a third specialist** (e.g. macOS, mainframe...): add another
  subfolder to `vm-template-repo`, a new `system_prompt_<x>.txt`, a new
  entry in `AGENT_PROFILES` in `deploy_agent.py`, run the script with
  `--target <x>`, then add the agent name to the orchestrator's prompt and
  the frontend's allow-list. No image rebuild needed if the tools are
  identical.
* **Regression rule:** after any new hosted-agent version, re-run RBAC for
  the new principal id. Forgetting this manifests as 403 on Terraform/KV
  operations from inside the agent. `deploy_all.py` does this automatically.
* **Token counter** sums tokens across orchestrator + specialist turns.
* **Workspace lifetime:** plan/state artifacts persist on the container
  instance for the life of that instance. Cold-start, scale-to-zero, or a
  new agent version drops them; the agent will re-clone & re-plan. For
  cross-instance persistence you'd need to mount a Files share at
  `/files/default/` (out of scope for this POC).
* **Updating prompts** requires both an image rebuild (so the file is in
  the container) **and** a `deploy_all.py` re-run (so Foundry picks up the
  same text as the agent's `instructions` field). The deploy script reads
  the prompt file from disk, so the workflow is:
  1. edit `agent/system_prompt_*.txt`
  2. `.\deploy\build_and_push.ps1 -Tag <new>`
  3. `$env:CONTAINER_IMAGE="...:<new>"; python deploy/deploy_all.py`
