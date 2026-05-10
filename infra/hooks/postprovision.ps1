#!/usr/bin/env pwsh
# Runs after `azd provision`. Builds the agent image into the freshly-
# provisioned ACR and deploys the orchestrator + 3 hosted agents to Foundry,
# wiring per-version managed-identity RBAC.
#
# Reads from the azd environment (populated by bicep outputs + preprovision):
#   AZURE_CONTAINER_REGISTRY_NAME    bicep output
#   AZURE_RESOURCE_GROUP             azd built-in
#   AZURE_SUBSCRIPTION_ID            azd built-in
#   TFSTATE_STORAGE_ACCOUNT_NAME     bicep output
#   KEYVAULT_URI / KEYVAULT_NAME     bicep output
#   FOUNDRY_PROJECT_ENDPOINT         user-set (bicep param)
#   FOUNDRY_RG                       user-set
#   FOUNDRY_ACCOUNT_NAME             derived in preprovision
#   FOUNDRY_PROJECT_NAME             derived in preprovision
#
# Optional:
#   AGENT_IMAGE_TAG                  default: 'latest' (Foundry pulls by digest
#                                    on each new agent version, so 'latest' is
#                                    safe — the digest still differs)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Need {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { throw "postprovision: env var $Name is not set" }
    return $v
}

$repoRoot = Resolve-Path "$PSScriptRoot/../.."
$acr      = Need 'AZURE_CONTAINER_REGISTRY_NAME'
$rg       = Need 'AZURE_RESOURCE_GROUP'
$tag      = if ($env:AGENT_IMAGE_TAG) { $env:AGENT_IMAGE_TAG } else { 'latest' }
$imageRef = "$acr.azurecr.io/vmagent-agent:$tag"

Write-Host "postprovision: building agent image $imageRef"
az acr build `
    --registry $acr `
    --image "vmagent-agent:$tag" `
    --file  "$repoRoot/agent/Dockerfile" `
    "$repoRoot/agent" `
    --no-logs | Out-Null
if ($LASTEXITCODE -ne 0) { throw "az acr build failed" }

# Grant AcrPull on the new ACR to the Foundry project's system-assigned
# managed identity. The project MI is what Foundry uses to pull the
# hosted-agent container image when create_version is called. Without
# this, the very first version provisioning fails with
# "Failed to pull container image". Idempotent — az role assignment create
# returns success if the assignment already exists.
$foundryRg2     = Need 'FOUNDRY_RG'
$foundryAcct2   = Need 'FOUNDRY_ACCOUNT_NAME'
$foundryProj2   = Need 'FOUNDRY_PROJECT_NAME'
$subId2         = if ($env:VM_TARGET_SUBSCRIPTION_ID) { $env:VM_TARGET_SUBSCRIPTION_ID } else { Need 'AZURE_SUBSCRIPTION_ID' }
$projUri        = "https://management.azure.com/subscriptions/$subId2/resourceGroups/$foundryRg2/providers/Microsoft.CognitiveServices/accounts/$foundryAcct2/projects/$foundryProj2" + '?api-version=2025-06-01'

Write-Host "postprovision: fetching Foundry project system-assigned MI principalId"
$projMiPid = az rest --method get --uri $projUri --query 'identity.principalId' -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($projMiPid) -or $projMiPid -eq 'null') {
    # Fall back to the account's MI (some Foundry deployments use the account MI for pulls).
    $acctUri   = "https://management.azure.com/subscriptions/$subId2/resourceGroups/$foundryRg2/providers/Microsoft.CognitiveServices/accounts/$foundryAcct2" + '?api-version=2025-06-01'
    $projMiPid = az rest --method get --uri $acctUri --query 'identity.principalId' -o tsv 2>$null
}
if ([string]::IsNullOrWhiteSpace($projMiPid) -or $projMiPid -eq 'null') {
    throw "Could not resolve Foundry project/account system-assigned MI principalId. Ensure the Foundry account has a system-assigned identity enabled."
}

$acrId = az acr show -n $acr -g $rg --query id -o tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrId)) { throw "Could not resolve ACR id for $acr" }

Write-Host "postprovision: granting AcrPull on $acr to Foundry MI $projMiPid"
az role assignment create `
    --assignee-object-id $projMiPid `
    --assignee-principal-type ServicePrincipal `
    --role 'AcrPull' `
    --scope $acrId 2>&1 | Out-Null
# rc != 0 with "already exists" message is fine; only fail if scope/principal genuinely bad.

# Grant 'Azure AI User' on the Foundry PROJECT scope to the frontend container
# app's user-assigned managed identity. This is what lets the frontend
# orchestrator call /agents/* data-plane operations (e.g. createResponse).
# Without it, the very first user message returns 403 with
# "does not have permissions for Microsoft.MachineLearningServices/workspaces/agents/action".
$frontendMiPid = $env:FRONTEND_IDENTITY_PRINCIPAL_ID
if ([string]::IsNullOrWhiteSpace($frontendMiPid)) {
    Write-Warning "postprovision: FRONTEND_IDENTITY_PRINCIPAL_ID not set; skipping Azure AI User grant on Foundry project. Frontend chats will return 403 until this is granted."
} else {
    $projScope = "/subscriptions/$subId2/resourceGroups/$foundryRg2/providers/Microsoft.CognitiveServices/accounts/$foundryAcct2/projects/$foundryProj2"
    Write-Host "postprovision: granting 'Azure AI User' on Foundry project to frontend MI $frontendMiPid"
    az role assignment create `
        --assignee-object-id $frontendMiPid `
        --assignee-principal-type ServicePrincipal `
        --role 'Azure AI User' `
        --scope $projScope 2>&1 | Out-Null
    # Idempotent: az returns success on duplicate; "already exists" is benign.
}

# Allow up to 60s for AAD propagation before downstream image pulls + agent calls.
Write-Host "postprovision: waiting 60s for RBAC propagation"
Start-Sleep -Seconds 60

# Derive KEYVAULT_NAME from URI if not already set (bicep emits both).
if (-not $env:KEYVAULT_NAME -and $env:KEYVAULT_URI) {
    if ($env:KEYVAULT_URI -match '^https?://([^.]+)\.vault\.azure\.net/?$') {
        $env:KEYVAULT_NAME = $Matches[1]
        azd env set KEYVAULT_NAME $env:KEYVAULT_NAME | Out-Null
    }
}

# Map azd-style names to what deploy_all.py expects.
$env:CONTAINER_IMAGE              = $imageRef
$env:TFSTATE_RESOURCE_GROUP       = $rg
$env:VM_TARGET_SUBSCRIPTION_ID    = if ($env:VM_TARGET_SUBSCRIPTION_ID) { $env:VM_TARGET_SUBSCRIPTION_ID } else { Need 'AZURE_SUBSCRIPTION_ID' }
# FOUNDRY_PROJECT_ENDPOINT, FOUNDRY_RG, FOUNDRY_ACCOUNT_NAME, FOUNDRY_PROJECT_NAME,
# TFSTATE_STORAGE_ACCOUNT_NAME, KEYVAULT_URI are inherited from azd env.

Write-Host "postprovision: ensuring deploy script dependencies"
python -m pip install -q -r "$repoRoot/requirements-deploy.txt"
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

Write-Host "postprovision: deploying orchestrator + 3 hosted agents to Foundry"
python "$repoRoot/deploy/deploy_all.py"
if ($LASTEXITCODE -ne 0) { throw "deploy_all.py failed" }

if ($env:EASY_AUTH_ENABLED -eq 'true') {
    Write-Host "postprovision: configuring Easy Auth (Entra SSO) on frontend container app"
    & "$PSScriptRoot/easyauth.ps1"
    if ($LASTEXITCODE -ne 0) { throw "easyauth.ps1 failed" }
} else {
    Write-Host "postprovision: Easy Auth disabled (set 'azd env set EASY_AUTH_ENABLED true' to enable)"
}

Write-Host "postprovision: complete. Run 'azd deploy' to push the frontend image."
