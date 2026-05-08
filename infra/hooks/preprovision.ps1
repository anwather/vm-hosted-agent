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
