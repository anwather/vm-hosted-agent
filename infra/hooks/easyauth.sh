#!/usr/bin/env bash
# Wire Microsoft Entra ID Easy Auth into the vmagent-frontend Container App.
#
# Idempotent. Gated on EASY_AUTH_ENABLED=true. EASY_AUTH_REGISTRATION_MODE
# controls who owns the Entra app registration:
#   managed  - this script creates / updates the app registration (default)
#   external - another team creates the app registration and returns the
#              client ID + secret for this script to apply to Container Apps
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

join_by_comma() {
    local out=""
    local item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        if [[ -n "$out" ]]; then
            out+=","
        fi
        out+="$item"
    done
    printf '%s' "$out"
}

write_delegated_handoff() {
    local reason="$1"

    cat <<EOF

easyauth: delegated registration mode is waiting on an externally managed Entra app registration.
easyauth: $reason

Send the following to the Entra team:
  Display name suggestion : $DISPLAY_NAME
  Tenant ID              : $TENANT_ID
  Redirect URI           : $REPLY_URL
  Sign-in audience       : AzureADMyOrg (single tenant)
  Enterprise app         : create the service principal / enterprise application as part of setup

Ask them to return:
  1. Application (client) ID
  2. Client secret value

Then rerun provisioning with:
  azd env set EASY_AUTH_ENABLED true
  azd env set EASY_AUTH_REGISTRATION_MODE external
  azd env set EASY_AUTH_CLIENT_ID <app-id>
  export EASY_AUTH_CLIENT_SECRET='<secret>'    # or persist with azd env set if acceptable for your workflow
  azd provision

Frontend app   : $APP_NAME
Public endpoint: https://${FQDN}/

EOF
}

ROTATE="${ROTATE:-}"
ALLOWED_TENANTS="${ALLOWED_TENANTS:-}"
MODE="${EASY_AUTH_REGISTRATION_MODE:-managed}"
MODE="${MODE,,}"
if [[ "$MODE" != "managed" && "$MODE" != "external" ]]; then
    echo "easyauth: unsupported EASY_AUTH_REGISTRATION_MODE '$MODE' (expected 'managed' or 'external')" >&2
    exit 1
fi

RG=$(need AZURE_RESOURCE_GROUP)
APP_NAME=$(need FRONTEND_APP_NAME)
FQDN=$(need FRONTEND_FQDN)
TENANT_ID="${EASY_AUTH_TENANT_ID:-${AZURE_TENANT_ID:-$(az account show --query tenantId -o tsv)}}"
[[ -n "$TENANT_ID" ]] || { echo "easyauth: could not resolve tenant id" >&2; exit 1; }

DISPLAY_NAME="${EASY_AUTH_APP_DISPLAY_NAME:-${APP_NAME}-easyauth}"
REPLY_URL="https://${FQDN}/.auth/login/aad/callback"
ISSUER_URL="https://sts.windows.net/${TENANT_ID}/v2.0"

EXISTING_CLIENT_ID=$(az containerapp auth microsoft show -n "$APP_NAME" -g "$RG" \
    --query 'registration.clientId' -o tsv 2>/dev/null || true)
[[ "$EXISTING_CLIENT_ID" == "null" ]] && EXISTING_CLIENT_ID=""

echo "easyauth: mode=$MODE tenant=$TENANT_ID app=$DISPLAY_NAME fqdn=$FQDN"

# 1. Resolve the app registration / credentials
SECRET_VALUE=""
if [[ "$MODE" == "managed" ]]; then
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
        EXISTING_REDIRECTS=$(az ad app show --id "$APP_ID" --query 'web.redirectUris' -o tsv)
        if ! grep -q -- "$REPLY_URL" <<<"$EXISTING_REDIRECTS"; then
            echo "easyauth: updating redirect URI to $REPLY_URL"
            az ad app update --id "$APP_ID" --web-redirect-uris "$REPLY_URL" --enable-id-token-issuance true >/dev/null
        fi
    fi

    SP_OID=$(az ad sp list --filter "appId eq '$APP_ID'" --query '[0].id' -o tsv 2>/dev/null || true)
    if [[ -z "$SP_OID" ]]; then
        echo "easyauth: creating service principal"
        az ad sp create --id "$APP_ID" >/dev/null
    fi
else
    APP_ID="${EASY_AUTH_CLIENT_ID:-}"
    APP_ID="${APP_ID//[$'\r\n\t ']}"
    if [[ -z "$APP_ID" ]]; then
        if [[ -n "$EXISTING_CLIENT_ID" ]]; then
            APP_ID="$EXISTING_CLIENT_ID"
            echo "easyauth: EASY_AUTH_CLIENT_ID not set; reusing existing Container Apps auth clientId=$APP_ID"
        else
            write_delegated_handoff "Provide the redirect URI to the Entra team, then rerun after they return the client ID + secret."
            exit 0
        fi
    fi

    if [[ -n "${EASY_AUTH_CLIENT_SECRET:-}" ]]; then
        SECRET_VALUE="$EASY_AUTH_CLIENT_SECRET"
    elif [[ "$ROTATE" == "1" || -z "$EXISTING_CLIENT_ID" || "$EXISTING_CLIENT_ID" != "$APP_ID" ]]; then
        if [[ "$ROTATE" == "1" ]]; then
            write_delegated_handoff "Secret rotation was requested, but EASY_AUTH_CLIENT_SECRET is not set."
        elif [[ -z "$EXISTING_CLIENT_ID" ]]; then
            write_delegated_handoff "The container app is not wired to Microsoft auth yet, so the externally provided client secret is required."
        else
            write_delegated_handoff "Container Apps auth is currently configured for clientId '$EXISTING_CLIENT_ID', so the secret for '$APP_ID' is required to switch it."
        fi
        exit 0
    else
        echo "easyauth: external app registration already configured for clientId=$APP_ID; reusing existing Container Apps secret"
    fi
fi

# 2. Client secret
if [[ "$MODE" == "managed" ]]; then
    if [[ -z "$EXISTING_CLIENT_ID" || "$EXISTING_CLIENT_ID" != "$APP_ID" || "$ROTATE" == "1" ]]; then
        if [[ "$ROTATE" == "1" ]]; then
            echo "easyauth: rotating client secret"
        elif [[ -z "$EXISTING_CLIENT_ID" ]]; then
            echo "easyauth: creating client secret (no existing Microsoft auth config)"
        else
            echo "easyauth: existing auth config points at appId=$EXISTING_CLIENT_ID; replacing secret"
        fi
        SECRET_VALUE=$(az ad app credential reset \
            --id "$APP_ID" \
            --display-name "containerapp-$APP_NAME" \
            --years 1 \
            --append \
            --query password -o tsv)
    else
        echo "easyauth: container app already wired to appId=$APP_ID; reusing existing secret (set ROTATE=1 to rotate)"
    fi
elif [[ -n "$SECRET_VALUE" ]]; then
    echo "easyauth: applying client secret supplied for external app registration"
fi

# 3. Microsoft identity provider
if [[ -n "${EASY_AUTH_ALLOWED_AUDIENCES:-}" ]]; then
    IFS=',' read -r -a aud_parts <<<"${EASY_AUTH_ALLOWED_AUDIENCES}"
    ALLOWED_AUDS=$(join_by_comma "${aud_parts[@]}")
else
    ALLOWED_AUDS="api://${APP_ID},${APP_ID}"
fi

MS_ARGS=(
    containerapp auth microsoft update
    -n "$APP_NAME" -g "$RG"
    --client-id "$APP_ID"
    --issuer "$ISSUER_URL"
    --allowed-token-audiences "$ALLOWED_AUDS"
    --yes
)
if [[ -n "$SECRET_VALUE" ]]; then
    # --client-secret and --client-secret-name are mutually exclusive; pass
    # only the value and let az manage the underlying containerapp secret.
    MS_ARGS+=(--client-secret "$SECRET_VALUE")
fi
echo "easyauth: configuring Microsoft identity provider"
az "${MS_ARGS[@]}" >/dev/null

# 4. Require auth + redirect anonymous traffic
echo "easyauth: enabling auth + RedirectToLoginPage"
az containerapp auth update \
    -n "$APP_NAME" -g "$RG" \
    --enabled true \
    --action RedirectToLoginPage \
    --redirect-provider azureactivedirectory \
    --excluded-paths '/health,/healthz' >/dev/null

# Auth sidecar is injected at revision-creation time only. Bump a stable
# revision suffix to force a new revision (idempotent: repeat runs no-op).
SUFFIX="easyauth-${APP_ID:0:8}"
CURRENT_SUFFIX=$(az containerapp show -n "$APP_NAME" -g "$RG" --query 'properties.template.revisionSuffix' -o tsv 2>/dev/null || true)
if [[ "$CURRENT_SUFFIX" != "$SUFFIX" ]]; then
    echo "easyauth: bumping revision suffix to '$SUFFIX' to inject auth sidecar"
    az containerapp update -n "$APP_NAME" -g "$RG" --revision-suffix "$SUFFIX" >/dev/null
else
    echo "easyauth: revision suffix already '$SUFFIX'; auth sidecar present"
fi

azd env set EASY_AUTH_APP_ID "$APP_ID" >/dev/null
azd env set EASY_AUTH_APP_DISPLAY_NAME "$DISPLAY_NAME" >/dev/null

cat <<EOF

easyauth: complete.
  registrationMode : $MODE
  appId            : $APP_ID
  displayName      : $DISPLAY_NAME
  redirectUri      : $REPLY_URL
  containerApp     : $APP_NAME
  publicEndpoint   : https://${FQDN}/

Sign in via https://${FQDN}/ (anonymous traffic now redirects to AAD).
EOF
