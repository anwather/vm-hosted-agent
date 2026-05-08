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

Write-Host "postprovision: complete. Run 'azd deploy' to push the frontend image."
