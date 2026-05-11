# Task Orchestrator

A Microsoft Foundry **multi-agent orchestration** demo:

* **Orchestrator** (Foundry persistent agent) — talks to the user, decides
  whether they want a Windows or Linux VM, then hands off.
* **Windows VM agent** (Foundry **hosted** agent, containerized) — collects
  parameters and runs Terraform.
* **Linux VM agent** (Foundry hosted agent, **same container image**, different
  env vars + system prompt + template subfolder) — same flow for Linux.
* **Pricing agent** (Foundry hosted agent, **same container image**, role
  `pricing`) — answers "how much will this VM cost?" by hitting the Azure
  retail-prices API. Either VM specialist may forward to pricing mid-build
  for an estimate; pricing always hands back to its caller.
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
   ├──►  vmagent-agent-windows  (hosted, role=vm-builder, OS=windows, tpl=windows/)
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
| `deploy/deploy_agent.py` | Deploys ONE hosted agent (`--target windows`, `--target linux`, or `--target pricing`). |
| `deploy/deploy_orchestrator.py` | Deploys/updates the persistent orchestrator agent. |
| `deploy/assign_rbac.py` | Assigns the post-deploy RBAC roles to a hosted agent's per-version managed identity. |
| `deploy/deploy_all.py` | One-shot: deploys all 3 hosted agents (windows, linux, pricing) + orchestrator and runs RBAC. |

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
  `rg-task-orchestrator`). All Bicep resources land here.
* The **Foundry resource group stays separate**. The template does not deploy
  ACR, Key Vault, Storage, or Container Apps into the Foundry RG.

### VM template repo (public)

The hosted agent clones VM templates at runtime from
<https://github.com/anwather/vm-template-repo> with no credentials. The
repo must remain **public** (or you must fork it and either keep the fork
public or extend `agent/tools/git_clone.py` to inject a PAT). Subfolders
`windows/` and `linux/` are the entry points; the `TEMPLATE_REPO_URL` and
`TEMPLATE_SUBFOLDER` env vars on each hosted agent point at them.

### Azure tenant / Entra ID requirements

* Tenant role **Application Administrator** (or Cloud Application
  Administrator / Global Administrator) on the deployer account — required
  only if you want this repo's Easy Auth hook to create the Entra App
  Registration for you. If another team creates the app registration
  separately, the frontend can still be wired manually later.
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
  `gpt-5.1`; rename in the prompt files if you use a different name). All
  four agents (orchestrator + windows + linux + pricing) share the single
  deployment.
* A **capability host** must exist on the Foundry CognitiveServices account
  before hosted agents can be created. **The `azd` path provisions this
  automatically** via `infra/hooks/preprovision.{ps1,sh}` (idempotent
  ARM PUT to `Microsoft.CognitiveServices/accounts/{acct}/capabilityHosts/agents?api-version=2025-10-01-preview`
  with body `{"properties":{"capabilityHostKind":"Agents"}}`). For the
  manual quickstart you must run this yourself before `deploy_all.py`:
  ```powershell
  $sub = (az account show --query id -o tsv)
  $capUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/<FOUNDRY_RG>/providers/Microsoft.CognitiveServices/accounts/<FOUNDRY_ACCT>/capabilityHosts/agents?api-version=2025-10-01-preview"
  $bodyFile = Join-Path $env:TEMP "caphost.json"
  '{ "properties": { "capabilityHostKind": "Agents" } }' | Out-File $bodyFile -Encoding ascii -NoNewline
  az rest --method put --uri $capUri --headers "Content-Type=application/json" --body "@$bodyFile"
  # Wait ~3-4 min, then poll until provisioningState=Succeeded:
  az rest --method get --uri $capUri --query properties.provisioningState -o tsv
  ```
  Without it, the first `deploy_agent.py` call returns `400: capability host not found`.
* The Foundry account must allow outbound to ACR (default allow-all is fine)
  so it can pull the agent image. The ACR is created by the Bicep with
  anonymous-pull **disabled**; the Foundry hosted-agent runtime authenticates
  to ACR with its system-assigned identity, so RBAC via `rbac-acrpull.bicep`
  is required (already wired in `infra/main.bicep`).

### Tooling on the deployer machine

* **Azure CLI ≥ 2.60** (`az login` with the right account). Container Apps
  and Foundry use newer commands than older CLI versions.
* **Python ≥ 3.11** with `python -m pip install -r requirements-deploy.txt`.
* **PowerShell 7+** if you use `deploy/build_and_push.ps1` (works on
  Linux/macOS too via `pwsh`).
* No Docker required — both paths build images in ACR:
  * **azd path**: `azure.yaml` declares `remoteBuild: true` for the
    `frontend` service, so `azd deploy frontend` uploads the build context
    to ACR and runs the build there. The hosted-agent image is built by
    `infra/hooks/postprovision.{ps1,sh}` via `az acr build` before
    `deploy_all.py` runs.
  * **Manual path**: `deploy/build_and_push.ps1` (and the README snippets)
    use `az acr build`.

  If you'd prefer a local Docker build (faster on a warm cache), remove
  `remoteBuild: true` from `azure.yaml` and ensure Docker Desktop is
  running before `azd up`.

### Network & policy

* No private endpoints in this demo — ACR, KV, and tfstate Storage are all
  public-endpoint with AAD-only auth. If your tenant policy requires PEs,
  you'll need to extend the Bicep with PE modules and ensure the Foundry
  hosted-agent egress can reach them.
* Shared-key access on Storage is **disabled** (`allowSharedKeyAccess: false`);
  the Terraform backend uses AAD auth via the agent's MI.

## Quickstart with `azd` (recommended)

If you have the [Azure Developer CLI](https://aka.ms/azd) installed, the
whole stack can be stood up with three commands. Hooks (`infra/hooks/`)
build the agent image, deploy the orchestrator + 3 hosted agents into
Foundry, and reassign per-version managed-identity RBAC.

```powershell
azd auth login
azd init                                # only on first clone — pick env name + region
azd env set AZURE_RESOURCE_GROUP      "rg-task-orchestrator"
azd env set FOUNDRY_PROJECT_ENDPOINT  "https://<acct>.services.ai.azure.com/api/projects/<proj>"
azd env set FOUNDRY_RG                "<foundry-rg>"
# Optional overrides:
# azd env set AGENT_IMAGE_TAG       latest         # default: latest
# azd env set VM_TARGET_SUBSCRIPTION_ID <sub-id>   # default: AZURE_SUBSCRIPTION_ID
azd up                                  # provision infra, build agent image, deploy agents, deploy frontend
```

`azd up` will:
1. Run `preprovision` to validate `FOUNDRY_PROJECT_ENDPOINT` + `FOUNDRY_RG`,
   set `AZURE_RESOURCE_GROUP` to a dedicated app RG if it is unset (defaults
   to `rg-<azd-env-name>`), refuse to reuse the Foundry RG for template infra,
   derive `FOUNDRY_ACCOUNT_NAME` / `FOUNDRY_PROJECT_NAME` into the azd env,
   and PUT the Foundry account's `agents` capability host (idempotent).
2. Provision infra (`infra/main.bicep`).
3. Run `postprovision` to:
   * `az acr build` the agent image into the new ACR
   * `python deploy/deploy_all.py` to (re)create the orchestrator + windows
     + linux + pricing hosted agents and assign RBAC to each new MI
4. Build & deploy the frontend container app image. Build runs **remotely
   in ACR** (via `remoteBuild: true` in `azure.yaml`) — no local Docker
   daemon required.

`AZURE_RESOURCE_GROUP` controls where azd creates and deletes the template
resources. `FOUNDRY_RG` must stay pointed at the existing Foundry account's
resource group; `azd down` only targets `AZURE_RESOURCE_GROUP`.

Easy Auth (Entra SSO) is **opt-in via `azd env set EASY_AUTH_ENABLED true`**.
When enabled, the postprovision hook (`infra/hooks/easyauth.ps1`) idempotently
creates the Entra app registration, generates a client secret, and wires the
container app's auth config — no manual step required. See
[**Optional: Easy Auth (Entra SSO)**](#optional-easy-auth-entra-sso) below.

To re-deploy just the agent code:
```powershell
azd provision        # re-runs postprovision (rebuilds image, new agent versions)
```

To re-deploy just the frontend:
```powershell
azd deploy frontend
```

### Optional: Easy Auth (Entra SSO)

The frontend container app is **anonymous by default** (no auth at the
ingress). To require Entra ID sign-in for everyone hitting the public URL,
opt in once before `azd up`:

```powershell
azd env set EASY_AUTH_ENABLED true
azd up                    # or `azd provision` if you've already run it
```

The postprovision hook (`infra/hooks/easyauth.ps1`, with a posix twin
`easyauth.sh`) will:

1. Create or update an Entra app registration named
   `<frontend-app-name>-easyauth` with redirect URI
   `https://<fqdn>/.auth/login/aad/callback`.
2. Generate a 1-year client secret (only on first run; reuses existing
   secret on subsequent runs — pass `-Rotate` to force rotation).
3. Wire `az containerapp auth microsoft update` and require sign-in
   (`--action RedirectToLoginPage`).
4. Persist `EASY_AUTH_APP_ID` + `EASY_AUTH_APP_DISPLAY_NAME` back to the
   azd env so subsequent runs are idempotent.

**Required permissions on the deployer account:**
* **Application Administrator** (or Cloud Application Admin / Global
  Admin) on the tenant — to create the app registration.
* **Owner** or **Contributor** on the resource group — already needed for
  the rest of the deploy.

### Manual / delegated Entra app registration

If the team running `azd` **cannot** create app registrations in Entra, split
the work:

1. **Platform / identity team** creates the Entra app registration and client
   secret.
2. **Deployment team** wires the existing app into the frontend Container App
   auth config.

#### What the identity team must create

Use the frontend FQDN from the deployed Container App and create a
**single-tenant** app registration with:

- **Display name:** any name you prefer (for example
  `<frontend-app-name>-easyauth`)
- **Redirect URI:** `https://<frontend-fqdn>/.auth/login/aad/callback`
- **ID tokens enabled:** yes
- **Sign-in audience:** `AzureADMyOrg`

Then create a **client secret** and provide these values to the deployment
team:

- `tenant_id`
- `client_id` (Application / app ID)
- `client_secret` (**the secret value itself**, captured when it is created)

> The client secret value is only shown once in Entra. Capture it at creation
> time and hand it over securely. It is not committed to the repo and should
> not be stored in source control.

#### How the deployment team uses the client secret

After the frontend Container App exists and you know its FQDN:

```powershell
$rg = "<app-resource-group>"
$appName = "<frontend-app-name>"
$fqdn = "<frontend-fqdn>"
$tenantId = "<tenant-id>"
$clientId = "<client-id>"
$clientSecret = "<client-secret-value>"
$issuer = "https://sts.windows.net/$tenantId/v2.0"

az containerapp auth microsoft update `
  -n $appName -g $rg `
  --client-id $clientId `
  --client-secret $clientSecret `
  --client-secret-name aad-client-secret `
  --tenant-id $tenantId `
  --issuer $issuer `
  --allowed-token-audiences "api://$clientId,$clientId" `
  --yes

az containerapp auth update `
  -n $appName -g $rg `
  --enabled true `
  --action RedirectToLoginPage `
  --redirect-provider azureactivedirectory `
  --excluded-paths '/.auth/*,/health,/healthz'
```

That command stores the secret in the Container App's secret store under the
name `aad-client-secret` and configures the Microsoft identity provider to use
it. The secret value does **not** need to be written into `azure.yaml`,
`azd` env files, or the repository.

Recommended follow-up so future operators know which app registration is in
use:

```powershell
azd env set EASY_AUTH_ENABLED true
azd env set EASY_AUTH_APP_ID $clientId
azd env set EASY_AUTH_APP_DISPLAY_NAME "<entra-app-display-name>"
```

If you later need to rotate the secret, the identity team creates a new client
secret on the same app registration and the deployment team reruns
`az containerapp auth microsoft update` with the **new secret value**.

To rotate the secret manually any time:
```powershell
$env:EASY_AUTH_ENABLED = 'true'
.\infra\hooks\easyauth.ps1 -Rotate
```

To remove Easy Auth:
```powershell
az containerapp auth update -n <frontend-app-name> -g <rg> --enabled false
azd env set EASY_AUTH_ENABLED false
```
(The Entra app registration persists — delete it manually with
`az ad app delete --id $(azd env get-value EASY_AUTH_APP_ID)` if desired.)

## Quickstart (manual, without azd)

Replace placeholders (`<...>`) with your values. Image versions shown
(`0.5.1`) match the current main branch — bump as you publish new tags.

```powershell
# 0) One-time: install deploy-script dependencies
python -m pip install -r requirements-deploy.txt
az login
az account set --subscription <TARGET_SUB_ID>

# 0a) Ensure the Foundry account has its 'agents' capability host (see
#     pre-reqs). Skip if you already provisioned it. Idempotent.
$sub = (az account show --query id -o tsv)
$capUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/<FOUNDRY_RG>/providers/Microsoft.CognitiveServices/accounts/<FOUNDRY_ACCT>/capabilityHosts/agents?api-version=2025-10-01-preview"
$bodyFile = Join-Path $env:TEMP "caphost.json"
'{ "properties": { "capabilityHostKind": "Agents" } }' | Out-File $bodyFile -Encoding ascii -NoNewline
az rest --method put --uri $capUri --headers "Content-Type=application/json" --body "@$bodyFile" | Out-Null
do { Start-Sleep 10; $s = az rest --method get --uri $capUri --query properties.provisioningState -o tsv; "  capabilityHost state=$s" } while ($s -notin 'Succeeded','Failed','Canceled')

# 1) Provision infra
az group create -n rg-task-orchestrator -l australiaeast
az deployment group create `
  -g rg-task-orchestrator `
  -f infra/main.bicep `
  -p targetSubscriptionId=<TARGET_SUB_ID> `
     foundryProjectEndpoint=https://<FOUNDRY_ACCT>.services.ai.azure.com/api/projects/<PROJECT>

# Capture outputs you'll reuse below
$out = az deployment group show -g rg-task-orchestrator -n main --query properties.outputs -o json | ConvertFrom-Json
$ACR   = $out.AZURE_CONTAINER_REGISTRY_NAME.value
$KVURI = $out.KEYVAULT_URI.value
$STG   = $out.TFSTATE_STORAGE_ACCOUNT_NAME.value
$FQDN  = $out.FRONTEND_FQDN.value

# 2) Build the agent + frontend images.
#    az acr build streaming logs can crash on Windows with a cp1252
#    UnicodeEncodeError — pass --no-logs and force UTF-8 console encoding.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
az acr build --registry $ACR --image vmagent-agent:0.5.1    --file agent/Dockerfile    agent    --no-logs
az acr build --registry $ACR --image vmagent-frontend:0.5.1 --file frontend/Dockerfile frontend --no-logs
#  (Convenience wrapper for the agent image: .\deploy\build_and_push.ps1 -Registry $ACR -Tag 0.5.1)

# 3) Deploy orchestrator + 3 hosted agents + RBAC in one shot
$env:FOUNDRY_PROJECT_ENDPOINT      = "https://<FOUNDRY_ACCT>.services.ai.azure.com/api/projects/<PROJECT>"
$env:CONTAINER_IMAGE               = "$ACR.azurecr.io/vmagent-agent:0.5.1"
$env:TFSTATE_STORAGE_ACCOUNT_NAME  = $STG
$env:TFSTATE_RESOURCE_GROUP        = "rg-task-orchestrator"
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
az containerapp update -n vmagent-frontend -g rg-task-orchestrator `
  --image "$ACR.azurecr.io/vmagent-frontend:0.5.1" `
  --set-env-vars FRONTEND_VERSION=0.5.1 `
                 ORCHESTRATOR_AGENT_NAME=taskorch-orchestrator `
                 HOSTED_AGENT_NAME_WINDOWS=vmagent-agent-windows `
                 HOSTED_AGENT_NAME_LINUX=vmagent-agent-linux `
                 HOSTED_AGENT_NAME_PRICING=vmagent-agent-pricing

# 5) Easy Auth (Entra) on the frontend — one-time, needs App Admin role
$appId = az ad app create --display-name "Task Orchestrator" `
  --web-redirect-uris "https://$FQDN/.auth/login/aad/callback" `
  --query appId -o tsv
$secret = az ad app credential reset --id $appId --years 1 --query password -o tsv
az containerapp auth microsoft update -n vmagent-frontend -g rg-task-orchestrator `
  --client-id $appId --client-secret $secret `
  --tenant-id (az account show --query tenantId -o tsv) --yes
az containerapp auth update -n vmagent-frontend -g rg-task-orchestrator `
  --enabled true --action RedirectToLoginPage --redirect-provider azureactivedirectory
```

Browse to `https://$FQDN`. Sign in. Type `I want a Windows VM` (or Linux).
You should see the orchestrator's brief reply, a `Handed off to <agent>.`
system bubble, then the specialist starts asking VM parameter questions.

### Re-deploys (image bump only)

After editing the agent code or prompts:

```powershell
.\deploy\build_and_push.ps1 -Registry $ACR -Tag 0.5.1   # publish a new tag
$env:CONTAINER_IMAGE = "$ACR.azurecr.io/vmagent-agent:0.5.1"
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

#### Azure region validation

All three agents share `validate_azure_region(region)` and
`list_azure_vm_regions()` (in `agent/tools/regions.py`). They source the
authoritative VM-region list from the same auth-free Azure Retail Prices
API used by the pricing tool — one probe SKU (`Standard_B2s`) is sold in
every public region, so its `armRegionName` set is the canonical list.
The list is cached in-process for 6 hours. On a miss the tool returns
`difflib`-based suggestions plus a hint about the expected short-code
format (e.g. `australiaeast`, `newzealandnorth`, `eastus`). The Windows /
Linux / Pricing prompts all instruct the agent to call
`validate_azure_region` BEFORE any region-consuming tool
(`set_tf_variables`, `get_vm_monthly_cost`) and never to assume that
their training data has the latest region list.

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

#### UI layout (frontend ≥ 0.5.0)

The page is a 2-pane grid:

* **Left — chat.** User and assistant bubbles. Routing/handback transitions
  appear as subtle inline dividers (`─── handed off to vmagent-agent-windows ───`)
  rather than verbose system bubbles.
* **Right — Agent activity.** A timeline of cards, one per agent
  engagement. Each card has a traffic-light dot:
  * 🟡 yellow — agent is starting / streaming / has a tool in flight
  * 🟢 green  — agent finished its turn cleanly
  * 🔴 red    — at least one tool errored
  Past cards auto-collapse when a new agent becomes active; click any
  header to re-expand. Tool calls render as collapsed `<details>` rows
  inside the active card (`status_dot · tool_name · short result`); click
  a row to reveal full arguments and result. Terraform output lives inside
  the relevant tool row — there is no longer a separate Terraform log
  pane.

A **theme toggle** (🌙 / ☀️) in the header switches between dark
(default) and light. The choice is persisted in `localStorage` and
applied before paint to avoid a flash.

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
    regions.py             validate_azure_region() / list_azure_vm_regions() — auth-free,
                           sourced from the Azure Retail Prices API; cached for 6h.
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

## Tear-down & clean rebuild

To wipe everything and rebuild from a fresh state (useful before a customer
demo). The Bicep does **not** own the Foundry CognitiveServices account
(you bring your own), so the Foundry project survives all teardown
commands below — the four hosted/persistent agents inside it must be
deleted explicitly.

```powershell
# A) If you used azd:
azd down --purge --force          # deletes the demo RG; purges KV/ACR soft-delete

# B) If you deployed manually:
az group delete -n rg-task-orchestrator --yes
# Key Vault has soft-delete enabled; purge it so the next deploy can reuse the name:
az keyvault purge --name <KV_NAME> --location australiaeast 2>$null

# Neither of the above deletes:
#   * the Foundry hosted/persistent agents (the Foundry account is BYO)
#   * the Entra app registration (Easy Auth)
#   * any VMs the agent created in your target subscription

# Delete the four agents from the Foundry project. Easiest path:
#   Foundry portal → Project → Agents → select each (taskorch-orchestrator,
#   vmagent-agent-windows, vmagent-agent-linux, vmagent-agent-pricing) → Delete.

# Delete the Entra app:
az ad app delete --id (az ad app list --display-name "Task Orchestrator" --query "[0].appId" -o tsv)

# C) Clean any test VMs the agent built (they live in the TARGET subscription,
#    NOT in rg-task-orchestrator). The agent uses RG names like 'demo-vm-<name>'.
az group list --query "[?starts_with(name,'demo-vm-')].name" -o tsv |
  ForEach-Object { az group delete -n $_ --yes --no-wait }
```

Then re-deploy with either `azd up` or the manual quickstart above. KV /
ACR / Storage names are suffixed with `uniqueString(resourceGroup().id)`,
so a fresh RG always gets fresh resource names.
