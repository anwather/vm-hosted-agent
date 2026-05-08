#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Wire Microsoft Entra ID Easy Auth into the vmagent-frontend Container App.

.DESCRIPTION
  Idempotently:
    1. Creates / updates an Entra app registration whose redirect URI matches
       the container app's FQDN.
    2. Creates a client secret (or rotates if -Rotate is passed).
    3. Configures the container app's auth config to require sign-in and use
       Microsoft as the identity provider.

  Gated on `EASY_AUTH_ENABLED=true` (azd env or environment) so users without
  Entra Application Administrator permission aren't forced into it.

  Required env vars (all set automatically by azd from main.bicep outputs):
    AZURE_RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID
    FRONTEND_APP_NAME, FRONTEND_FQDN

  The signed-in user must have the Microsoft Graph permission to create app
  registrations (e.g. Application Administrator, Cloud Application Admin, or
  Global Administrator).

.PARAMETER Rotate
  Force rotation of the client secret even if one already exists.

.PARAMETER AllowedTenants
  Comma-separated list of tenant IDs allowed to sign in. Defaults to the
  current tenant (single-tenant). Pass 'common' to allow any work / school
  account.
#>

param(
    [switch]$Rotate,
    [string]$AllowedTenants = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($env:EASY_AUTH_ENABLED -ne 'true') {
    Write-Host "easyauth: EASY_AUTH_ENABLED is not 'true'; skipping. (Run 'azd env set EASY_AUTH_ENABLED true' to enable.)"
    exit 0
}

function Need {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($v)) { throw "easyauth: env var $Name is not set" }
    return $v
}

$rg          = Need 'AZURE_RESOURCE_GROUP'
$appName     = Need 'FRONTEND_APP_NAME'
$fqdn        = Need 'FRONTEND_FQDN'
$tenantId    = if ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { az account show --query tenantId -o tsv }
if ([string]::IsNullOrWhiteSpace($tenantId)) { throw 'easyauth: could not resolve tenant id' }

$displayName = "$appName-easyauth"
$replyUrl    = "https://$fqdn/.auth/login/aad/callback"
$logoutUrl   = "https://$fqdn/.auth/logout"
$issuerUrl   = "https://sts.windows.net/$tenantId/v2.0"

Write-Host "easyauth: tenant=$tenantId app=$displayName fqdn=$fqdn"

# ---------------------------------------------------------------------------
# 1. Find or create the app registration (idempotent)
# ---------------------------------------------------------------------------
$appJson = az ad app list --display-name $displayName --query '[0]' -o json 2>$null
$app     = if ($appJson -and $appJson -ne 'null') { $appJson | ConvertFrom-Json } else { $null }

if ($null -eq $app) {
    Write-Host "easyauth: creating app registration '$displayName'"
    $appId = az ad app create `
        --display-name $displayName `
        --sign-in-audience AzureADMyOrg `
        --web-redirect-uris $replyUrl `
        --enable-id-token-issuance true `
        --query appId -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($appId)) { throw 'easyauth: app create failed' }
} else {
    $appId = $app.appId
    Write-Host "easyauth: app registration '$displayName' already exists (appId=$appId)"
    # Make sure redirect URI is current (FQDN can change on env recreation).
    $existingReplies = ($app.web.redirectUris) -join ','
    if ($existingReplies -notmatch [Regex]::Escape($replyUrl)) {
        Write-Host "easyauth: updating redirect URI to $replyUrl"
        az ad app update --id $appId --web-redirect-uris $replyUrl --enable-id-token-issuance true | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'easyauth: app update (redirect URI) failed' }
    }
}

# Ensure a service principal exists (containerapp auth needs this).
$spOid = az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($spOid)) {
    Write-Host "easyauth: creating service principal for appId=$appId"
    az ad sp create --id $appId | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'easyauth: sp create failed' }
}

# ---------------------------------------------------------------------------
# 2. Client secret — only create on first run (or -Rotate)
# ---------------------------------------------------------------------------
$secretName = 'aad-client-secret'
$existingSecret = az containerapp secret list -n $appName -g $rg `
    --query "[?name=='$secretName'].name | [0]" -o tsv 2>$null

if ([string]::IsNullOrWhiteSpace($existingSecret) -or $Rotate) {
    if ($Rotate -and -not [string]::IsNullOrWhiteSpace($existingSecret)) {
        Write-Host "easyauth: rotating client secret"
    } else {
        Write-Host "easyauth: creating client secret"
    }
    $secretValue = az ad app credential reset `
        --id $appId `
        --display-name "containerapp-$appName" `
        --years 1 `
        --append `
        --query password -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($secretValue)) {
        throw 'easyauth: credential reset failed (need Application Administrator?)'
    }
} else {
    Write-Host "easyauth: client secret already present on container app; reusing (use -Rotate to force rotation)"
    $secretValue = $null
}

# ---------------------------------------------------------------------------
# 3. Configure container app auth — Microsoft provider + require auth
# ---------------------------------------------------------------------------
$tenantClause = if ($AllowedTenants) {
    @{ allowedTenants = $AllowedTenants -split ',' }
} else {
    @{ allowedTenants = @($tenantId) }
}

# Set the Microsoft identity provider. If we just rotated/created a secret,
# pass it through; otherwise leave the existing secret in place.
$msUpdateArgs = @(
    'containerapp', 'auth', 'microsoft', 'update',
    '-n', $appName, '-g', $rg,
    '--client-id', $appId,
    '--tenant-id', $tenantId,
    '--issuer', $issuerUrl,
    '--allowed-token-audiences', "api://$appId,$appId",
    '--yes'
)
if ($secretValue) {
    $msUpdateArgs += @('--client-secret', $secretValue,
                       '--client-secret-name', $secretName)
}

Write-Host "easyauth: configuring Microsoft identity provider on container app"
& az @msUpdateArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'easyauth: az containerapp auth microsoft update failed' }

# Top-level auth: enable globally and require sign-in.
Write-Host "easyauth: enabling auth + RedirectToLoginPage on container app"
az containerapp auth update `
    -n $appName -g $rg `
    --enabled true `
    --action RedirectToLoginPage `
    --redirect-provider azureactivedirectory `
    --excluded-paths '/.auth/*,/health,/healthz' `
    | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'easyauth: az containerapp auth update failed' }

# Persist app id back to azd env for future runs / down-cleanup.
azd env set EASY_AUTH_APP_ID $appId | Out-Null
azd env set EASY_AUTH_APP_DISPLAY_NAME $displayName | Out-Null

Write-Host ""
Write-Host "easyauth: complete."
Write-Host "  appId            : $appId"
Write-Host "  displayName      : $displayName"
Write-Host "  redirectUri      : $replyUrl"
Write-Host "  containerApp     : $appName"
Write-Host "  publicEndpoint   : https://$fqdn/"
Write-Host ""
Write-Host "Sign in via https://$fqdn/ (anonymous traffic now redirects to AAD)."
