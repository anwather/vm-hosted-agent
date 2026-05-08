#!/usr/bin/env bash
# Wire Microsoft Entra ID Easy Auth into the vmagent-frontend Container App.
#
# Idempotent. Gated on EASY_AUTH_ENABLED=true. See easyauth.ps1 for the full
# behavioural contract; this is the bash twin called from postprovision.sh.
#
# Required env: AZURE_RESOURCE_GROUP, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID,
#               FRONTEND_APP_NAME, FRONTEND_FQDN

set -euo pipefail

if [[ "${EASY_AUTH_ENABLED:-}" != "true" ]]; then
    echo "easyauth: EASY_AUTH_ENABLED is not 'true'; skipping. (Run 'azd env set EASY_AUTH_ENABLED true' to enable.)"
    exit 0
fi

need() {
    local var="$1"
    local val="${!var:-}"
    if [[ -z "$val" ]]; then
        echo "easyauth: env var $var is not set" >&2
        exit 1
    fi
    echo "$val"
}

ROTATE="${ROTATE:-}"
ALLOWED_TENANTS="${ALLOWED_TENANTS:-}"

RG=$(need AZURE_RESOURCE_GROUP)
APP_NAME=$(need FRONTEND_APP_NAME)
FQDN=$(need FRONTEND_FQDN)
TENANT_ID="${AZURE_TENANT_ID:-$(az account show --query tenantId -o tsv)}"
[[ -n "$TENANT_ID" ]] || { echo "easyauth: could not resolve tenant id"; exit 1; }

DISPLAY_NAME="${APP_NAME}-easyauth"
REPLY_URL="https://${FQDN}/.auth/login/aad/callback"
ISSUER_URL="https://sts.windows.net/${TENANT_ID}/v2.0"

echo "easyauth: tenant=$TENANT_ID app=$DISPLAY_NAME fqdn=$FQDN"

# 1. Find / create app registration
APP_ID=$(az ad app list --display-name "$DISPLAY_NAME" --query '[0].appId' -o tsv 2>/dev/null || true)
if [[ -z "$APP_ID" || "$APP_ID" == "null" ]]; then
    echo "easyauth: creating app registration '$DISPLAY_NAME'"
    APP_ID=$(az ad app create \
        --display-name "$DISPLAY_NAME" \
        --sign-in-audience AzureADMyOrg \
        --web-redirect-uris "$REPLY_URL" \
        --enable-id-token-issuance true \
        --query appId -o tsv)
else
    echo "easyauth: app registration '$DISPLAY_NAME' already exists (appId=$APP_ID)"
    EXISTING=$(az ad app show --id "$APP_ID" --query 'web.redirectUris' -o tsv)
    if ! grep -q -- "$REPLY_URL" <<<"$EXISTING"; then
        echo "easyauth: updating redirect URI to $REPLY_URL"
        az ad app update --id "$APP_ID" --web-redirect-uris "$REPLY_URL" --enable-id-token-issuance true >/dev/null
    fi
fi

# 2. Service principal
SP_OID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv 2>/dev/null || true)
if [[ -z "$SP_OID" ]]; then
    echo "easyauth: creating service principal"
    az ad sp create --id "$APP_ID" >/dev/null
fi

# 3. Client secret (idempotent — only create on first run unless ROTATE=1)
SECRET_NAME="aad-client-secret"
EXISTING_SECRET=$(az containerapp secret list -n "$APP_NAME" -g "$RG" \
    --query "[?name=='$SECRET_NAME'].name | [0]" -o tsv 2>/dev/null || true)
SECRET_VALUE=""
if [[ -z "$EXISTING_SECRET" || "$ROTATE" == "1" ]]; then
    echo "easyauth: $( [[ -n "$EXISTING_SECRET" ]] && echo 'rotating' || echo 'creating' ) client secret"
    SECRET_VALUE=$(az ad app credential reset \
        --id "$APP_ID" \
        --display-name "containerapp-$APP_NAME" \
        --years 1 \
        --append \
        --query password -o tsv)
else
    echo "easyauth: client secret already present; reusing (set ROTATE=1 to rotate)"
fi

# 4. Microsoft identity provider
ALLOWED_AUDS="api://${APP_ID},${APP_ID}"
MS_ARGS=(
    containerapp auth microsoft update
    -n "$APP_NAME" -g "$RG"
    --client-id "$APP_ID"
    --tenant-id "$TENANT_ID"
    --issuer "$ISSUER_URL"
    --allowed-token-audiences "$ALLOWED_AUDS"
    --yes
)
if [[ -n "$SECRET_VALUE" ]]; then
    MS_ARGS+=(--client-secret "$SECRET_VALUE" --client-secret-name "$SECRET_NAME")
fi
echo "easyauth: configuring Microsoft identity provider"
az "${MS_ARGS[@]}" >/dev/null

# 5. Require auth + redirect anonymous traffic
echo "easyauth: enabling auth + RedirectToLoginPage"
az containerapp auth update \
    -n "$APP_NAME" -g "$RG" \
    --enabled true \
    --action RedirectToLoginPage \
    --redirect-provider azureactivedirectory \
    --excluded-paths '/.auth/*,/health,/healthz' >/dev/null

azd env set EASY_AUTH_APP_ID "$APP_ID" >/dev/null
azd env set EASY_AUTH_APP_DISPLAY_NAME "$DISPLAY_NAME" >/dev/null

cat <<EOF

easyauth: complete.
  appId            : $APP_ID
  displayName      : $DISPLAY_NAME
  redirectUri      : $REPLY_URL
  containerApp     : $APP_NAME
  publicEndpoint   : https://${FQDN}/

Sign in via https://${FQDN}/ (anonymous traffic now redirects to AAD).
EOF
