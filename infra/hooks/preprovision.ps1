#!/usr/bin/env pwsh
# Validates env vars required by the postprovision hook + deploy_all.py.
# azd already prompts for FOUNDRY_PROJECT_ENDPOINT (it's a bicep param);
# here we sanity-check it and the foundry RG, plus derive account/project
# names from the endpoint URL so they're available to later hooks.

$ErrorActionPreference = 'Stop'

function Require-EnvVar {
    param([string]$Name, [string]$Hint)
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name))) {
        Write-Error @"
Missing required env var: $Name
$Hint

Set with: azd env set $Name <value>
"@
        exit 1
    }
}

Require-EnvVar 'FOUNDRY_PROJECT_ENDPOINT' 'Full Foundry project endpoint, e.g. https://myacct.services.ai.azure.com/api/projects/myproj'
Require-EnvVar 'FOUNDRY_RG'                'Resource group of the Foundry CognitiveServices account'

$endpoint = $env:FOUNDRY_PROJECT_ENDPOINT
if ($endpoint -notmatch '^https?://([^.]+)\.services\.ai\.azure\.com/api/projects/([^/?#]+)/?$') {
    Write-Error "FOUNDRY_PROJECT_ENDPOINT does not match expected pattern https://<acct>.services.ai.azure.com/api/projects/<proj>"
    exit 1
}

$account = $Matches[1]
$project = $Matches[2]

# Surface derived values into the azd env so postprovision + frontend can read them
azd env set FOUNDRY_ACCOUNT_NAME $account | Out-Null
azd env set FOUNDRY_PROJECT_NAME $project | Out-Null

Write-Host "preprovision: FOUNDRY_ACCOUNT_NAME=$account, FOUNDRY_PROJECT_NAME=$project"

# Self-heal: a previous version of this template defaulted hostedAgentName
# to 'vmagent-agent-windows', which then caused bicep to compute the
# Windows hosted agent name as 'vmagent-agent-windows-windows'. azd persists
# the bad outputs into the env file, so subsequent runs reproduce the bug
# even after the template fix. Detect & reset.
$bad = $env:HOSTED_AGENT_NAME
if ($bad -and $bad -match '-(windows|linux|pricing)$') {
    Write-Host "preprovision: detected legacy HOSTED_AGENT_NAME='$bad' (suffixed) — resetting to 'vmagent-agent'"
    azd env set HOSTED_AGENT_NAME 'vmagent-agent' | Out-Null
    $env:HOSTED_AGENT_NAME = 'vmagent-agent'
    foreach ($k in 'HOSTED_AGENT_NAME_WINDOWS','HOSTED_AGENT_NAME_LINUX','HOSTED_AGENT_NAME_PRICING') {
        if ([Environment]::GetEnvironmentVariable($k)) {
            azd env set $k '' | Out-Null
            [Environment]::SetEnvironmentVariable($k, $null)
        }
    }
}

# Ensure the Foundry account has its 'agents' capability host. Required
# before any hosted agent can be created. Idempotent: PUT returns the
# existing resource if it's already there. Takes ~3-4 min on first create.
$foundryRg  = $env:FOUNDRY_RG
$subId      = (az account show --query id -o tsv)
$apiVersion = '2025-10-01-preview'
$capHostUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$foundryRg/providers/Microsoft.CognitiveServices/accounts/$account/capabilityHosts/agents?api-version=$apiVersion"

$state = az rest --method get --uri $capHostUri --query 'properties.provisioningState' -o tsv 2>$null
if ($LASTEXITCODE -eq 0 -and $state -eq 'Succeeded') {
    Write-Host "preprovision: capability host 'agents' already provisioned (state=$state)"
} else {
    Write-Host "preprovision: provisioning capability host 'agents' on Foundry account $account (this can take ~3-4 minutes)"
    $bodyFile = Join-Path $env:TEMP "caphost-body-$([guid]::NewGuid()).json"
    '{ "properties": { "capabilityHostKind": "Agents" } }' | Out-File -FilePath $bodyFile -Encoding ascii -NoNewline
    try {
        az rest --method put --uri $capHostUri --headers "Content-Type=application/json" --body "@$bodyFile" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to PUT capability host on $account" }
    } finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 10
        $state = az rest --method get --uri $capHostUri --query 'properties.provisioningState' -o tsv 2>$null
        Write-Host "preprovision: capability host state=$state"
        if ($state -eq 'Succeeded') { break }
        if ($state -eq 'Failed' -or $state -eq 'Canceled') { throw "Capability host provisioning ended in state $state" }
    }
    if ($state -ne 'Succeeded') { throw "Capability host did not reach Succeeded after 10 minutes (last state=$state)" }
}
