#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Wire Microsoft Entra ID Easy Auth into the vmagent-frontend Container App.

.DESCRIPTION
  Idempotently:
    1. In managed mode, creates / updates an Entra app registration whose
       redirect URI matches the container app's FQDN.
    2. In managed mode, creates a client secret (or rotates if -Rotate is
       passed). In external mode, uses EASY_AUTH_CLIENT_ID and
       EASY_AUTH_CLIENT_SECRET supplied by another team.
    3. Configures the container app's auth config to require sign-in and use
       Microsoft as the identity provider.

  Gated on `EASY_AUTH_ENABLED=true` (azd env or environment) so users without
  Entra Application Administrator permission are not forced into it.

  EASY_AUTH_REGISTRATION_MODE controls who owns the Entra app registration:
    managed  - this script creates / updates the app registration (default)
    external - another team creates the app registration and returns the
               client ID + secret for this script to apply to Container Apps

  Required env vars (all set automatically by azd from main.bicep outputs):
    AZURE_RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID
    FRONTEND_APP_NAME, FRONTEND_FQDN

  The signed-in user needs Microsoft Graph app-registration permissions only
  in managed mode.

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

function Split-CommaSeparated {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Write-DelegatedHandoff {
    param(
        [string]$DisplayName,
        [string]$TenantId,
        [string]$ReplyUrl,
        [string]$AppName,
        [string]$Fqdn,
        [string]$Reason
    )

    Write-Host ""
    Write-Host "easyauth: delegated registration mode is waiting on an externally managed Entra app registration."
    if ($Reason) {
        Write-Host "easyauth: $Reason"
    }
    Write-Host ""
    Write-Host "Send the following to the Entra team:"
    Write-Host "  Display name suggestion : $DisplayName"
    Write-Host "  Tenant ID              : $TenantId"
    Write-Host "  Redirect URI           : $ReplyUrl"
    Write-Host "  Sign-in audience       : AzureADMyOrg (single tenant)"
    Write-Host "  Enterprise app         : create the service principal / enterprise application as part of setup"
    Write-Host ""
    Write-Host "Ask them to return:"
    Write-Host "  1. Application (client) ID"
    Write-Host "  2. Client secret value"
    Write-Host ""
    Write-Host "Then rerun provisioning with:"
    Write-Host "  azd env set EASY_AUTH_ENABLED true"
    Write-Host "  azd env set EASY_AUTH_REGISTRATION_MODE external"
    Write-Host "  azd env set EASY_AUTH_CLIENT_ID <app-id>"
    Write-Host "  `$env:EASY_AUTH_CLIENT_SECRET = '<secret>'    # or persist with azd env set if acceptable for your workflow"
    Write-Host "  azd provision"
    Write-Host ""
    Write-Host "Frontend app   : $AppName"
    Write-Host "Public endpoint: https://$Fqdn/"
    Write-Host ""
}

$rg       = Need 'AZURE_RESOURCE_GROUP'
$appName  = Need 'FRONTEND_APP_NAME'
$fqdn     = Need 'FRONTEND_FQDN'
$mode     = if ($env:EASY_AUTH_REGISTRATION_MODE) { $env:EASY_AUTH_REGISTRATION_MODE.Trim().ToLowerInvariant() } else { 'managed' }
if ($mode -notin @('managed', 'external')) {
    throw "easyauth: unsupported EASY_AUTH_REGISTRATION_MODE '$mode' (expected 'managed' or 'external')"
}

$tenantId = if ($env:EASY_AUTH_TENANT_ID) {
    $env:EASY_AUTH_TENANT_ID
} elseif ($env:AZURE_TENANT_ID) {
    $env:AZURE_TENANT_ID
} else {
    az account show --query tenantId -o tsv
}
if ([string]::IsNullOrWhiteSpace($tenantId)) { throw 'easyauth: could not resolve tenant id' }

$displayName = if ($env:EASY_AUTH_APP_DISPLAY_NAME) { $env:EASY_AUTH_APP_DISPLAY_NAME } else { "$appName-easyauth" }
$replyUrl    = "https://$fqdn/.auth/login/aad/callback"
$issuerUrl   = "https://sts.windows.net/$tenantId/v2.0"

$existingClientId = az containerapp auth microsoft show -n $appName -g $rg `
    --query 'registration.clientId' -o tsv 2>$null
if ($existingClientId -eq 'null') { $existingClientId = $null }

Write-Host "easyauth: mode=$mode tenant=$tenantId app=$displayName fqdn=$fqdn"

# ---------------------------------------------------------------------------
# 1. Resolve the app registration / credentials
# ---------------------------------------------------------------------------
$secretValue = $null
if ($mode -eq 'managed') {
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
        $existingReplies = ($app.web.redirectUris) -join ','
        if ($existingReplies -notmatch [Regex]::Escape($replyUrl)) {
            Write-Host "easyauth: updating redirect URI to $replyUrl"
            az ad app update --id $appId --web-redirect-uris $replyUrl --enable-id-token-issuance true | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'easyauth: app update (redirect URI) failed' }
        }
    }

    $spOid = az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($spOid)) {
        Write-Host "easyauth: creating service principal for appId=$appId"
        az ad sp create --id $appId | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'easyauth: sp create failed' }
    }
} else {
    $appId = if ($env:EASY_AUTH_CLIENT_ID) { $env:EASY_AUTH_CLIENT_ID.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($appId)) {
        if ($existingClientId) {
            $appId = $existingClientId
            Write-Host "easyauth: EASY_AUTH_CLIENT_ID not set; reusing existing Container Apps auth clientId=$appId"
        } else {
            Write-DelegatedHandoff `
                -DisplayName $displayName `
                -TenantId $tenantId `
                -ReplyUrl $replyUrl `
                -AppName $appName `
                -Fqdn $fqdn `
                -Reason 'Provide the redirect URI to the Entra team, then rerun after they return the client ID + secret.'
            exit 0
        }
    }

    if ($env:EASY_AUTH_CLIENT_SECRET) {
        $secretValue = $env:EASY_AUTH_CLIENT_SECRET
    } elseif ($Rotate -or -not $existingClientId -or $existingClientId -ne $appId) {
        $reason = if ($Rotate) {
            'Secret rotation was requested, but EASY_AUTH_CLIENT_SECRET is not set.'
        } elseif (-not $existingClientId) {
            'The container app is not wired to Microsoft auth yet, so the externally provided client secret is required.'
        } else {
            "Container Apps auth is currently configured for clientId '$existingClientId', so the secret for '$appId' is required to switch it."
        }
        Write-DelegatedHandoff `
            -DisplayName $displayName `
            -TenantId $tenantId `
            -ReplyUrl $replyUrl `
            -AppName $appName `
            -Fqdn $fqdn `
            -Reason $reason
        exit 0
    } else {
        Write-Host "easyauth: external app registration already configured for clientId=$appId; reusing existing Container Apps secret"
    }
}

# ---------------------------------------------------------------------------
# 2. Client secret
# ---------------------------------------------------------------------------
if ($mode -eq 'managed') {
    if ([string]::IsNullOrWhiteSpace($existingClientId) -or $existingClientId -ne $appId -or $Rotate) {
        if ($Rotate) {
            Write-Host "easyauth: rotating client secret"
        } elseif ([string]::IsNullOrWhiteSpace($existingClientId)) {
            Write-Host "easyauth: creating client secret (no existing Microsoft auth config)"
        } else {
            Write-Host "easyauth: existing auth config points at a different appId ($existingClientId); replacing secret"
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
        Write-Host "easyauth: container app already wired to appId=$appId; reusing existing secret (use -Rotate to force rotation)"
        $secretValue = $null
    }
} elseif ($secretValue) {
    Write-Host "easyauth: applying client secret supplied for external app registration"
}

# ---------------------------------------------------------------------------
# 3. Configure container app auth - Microsoft provider + require auth
# ---------------------------------------------------------------------------
$allowedAudiences = Split-CommaSeparated $env:EASY_AUTH_ALLOWED_AUDIENCES
if ($allowedAudiences.Count -eq 0) {
    $allowedAudiences = @("api://$appId", $appId)
}

$msUpdateArgs = @(
    'containerapp', 'auth', 'microsoft',
    'update',
    '-n', $appName, '-g', $rg,
    '--client-id', $appId,
    '--issuer', $issuerUrl,
    '--allowed-token-audiences', ($allowedAudiences -join ','),
    '--yes'
)
if ($secretValue) {
    # Pass only --client-secret; az auto-creates a containerapp secret to hold
    # it. --client-secret and --client-secret-name are mutually exclusive.
    $msUpdateArgs += @('--client-secret', $secretValue)
}

Write-Host "easyauth: configuring Microsoft identity provider on container app"
& az @msUpdateArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'easyauth: az containerapp auth microsoft update failed' }

Write-Host "easyauth: enabling auth + RedirectToLoginPage on container app"
az containerapp auth update `
    -n $appName -g $rg `
    --enabled true `
    --action RedirectToLoginPage `
    --redirect-provider azureactivedirectory `
    --excluded-paths '/health,/healthz' `
    | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'easyauth: az containerapp auth update failed' }

# The auth sidecar is injected at revision-creation time, so an existing
# revision will keep returning 404 on /.auth/* until a NEW revision is
# created. Bump a revision suffix derived from a short hash of the appId
# so repeated runs do not keep creating new revisions unnecessarily.
$suffix = "easyauth-" + ($appId.Substring(0, 8))
$currentSuffix = az containerapp show -n $appName -g $rg --query 'properties.template.revisionSuffix' -o tsv 2>$null
if ($currentSuffix -ne $suffix) {
    Write-Host "easyauth: bumping revision suffix to '$suffix' to inject auth sidecar"
    az containerapp update -n $appName -g $rg --revision-suffix $suffix | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'easyauth: revision bump failed' }
} else {
    Write-Host "easyauth: revision suffix already '$suffix'; auth sidecar present"
}

azd env set EASY_AUTH_APP_ID $appId | Out-Null
azd env set EASY_AUTH_APP_DISPLAY_NAME $displayName | Out-Null

Write-Host ""
Write-Host "easyauth: complete."
Write-Host "  registrationMode : $mode"
Write-Host "  appId            : $appId"
Write-Host "  displayName      : $displayName"
Write-Host "  redirectUri      : $replyUrl"
Write-Host "  containerApp     : $appName"
Write-Host "  publicEndpoint   : https://$fqdn/"
Write-Host ""
Write-Host "Sign in via https://$fqdn/ (anonymous traffic now redirects to AAD)."
