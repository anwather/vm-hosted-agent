#!/usr/bin/env sh
# Validates env vars required by the postprovision hook + deploy_all.py.
# Also makes sure azd deploys the template infra into a resource group that is
# separate from the existing Foundry resource group.
set -e

require_env() {
    name="$1"
    hint="$2"
    val=$(printenv "$name" || true)
    if [ -z "$val" ]; then
        echo "Missing required env var: $name" 1>&2
        echo "$hint" 1>&2
        echo "Set with: azd env set $name <value>" 1>&2
        exit 1
    fi
}

require_env FOUNDRY_PROJECT_ENDPOINT 'Full Foundry project endpoint, e.g. https://myacct.services.ai.azure.com/api/projects/myproj'
require_env FOUNDRY_RG               'Resource group of the Foundry CognitiveServices account'

normalize_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs
}

infra_rg="${AZURE_RESOURCE_GROUP:-}"
env_name="${AZURE_ENV_NAME:-}"
if [ -z "$infra_rg" ]; then
    if [ -z "$env_name" ]; then
        echo "Missing required env var: AZURE_RESOURCE_GROUP" 1>&2
        echo "Could not derive a default because AZURE_ENV_NAME is not set." 1>&2
        echo "Set with: azd env set AZURE_RESOURCE_GROUP <new-resource-group-name>" 1>&2
        exit 1
    fi

    infra_rg="rg-$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]' | xargs)"
    azd env set AZURE_RESOURCE_GROUP "$infra_rg" >/dev/null
    export AZURE_RESOURCE_GROUP="$infra_rg"
    echo "preprovision: defaulting AZURE_RESOURCE_GROUP to $infra_rg"
fi

if [ "$(normalize_name "$infra_rg")" = "$(normalize_name "$FOUNDRY_RG")" ]; then
    echo "AZURE_RESOURCE_GROUP and FOUNDRY_RG must be different resource groups." 1>&2
    echo "azd provisions the template infrastructure into AZURE_RESOURCE_GROUP, while FOUNDRY_RG must point at the existing Foundry account's resource group." 1>&2
    echo "" 1>&2
    echo "Current values:" 1>&2
    echo "  AZURE_RESOURCE_GROUP = $infra_rg" 1>&2
    echo "  FOUNDRY_RG           = $FOUNDRY_RG" 1>&2
    echo "" 1>&2
    echo "Set with: azd env set AZURE_RESOURCE_GROUP <new-resource-group-name>" 1>&2
    exit 1
fi

endpoint="$FOUNDRY_PROJECT_ENDPOINT"
account=$(printf '%s' "$endpoint" | sed -nE 's#^https?://([^.]+)\.services\.ai\.azure\.com/api/projects/([^/?#]+)/?$#\1#p')
project=$(printf '%s' "$endpoint" | sed -nE 's#^https?://([^.]+)\.services\.ai\.azure\.com/api/projects/([^/?#]+)/?$#\2#p')

if [ -z "$account" ] || [ -z "$project" ]; then
    echo "FOUNDRY_PROJECT_ENDPOINT does not match expected pattern https://<acct>.services.ai.azure.com/api/projects/<proj>" 1>&2
    exit 1
fi

azd env set FOUNDRY_ACCOUNT_NAME "$account" >/dev/null
azd env set FOUNDRY_PROJECT_NAME "$project" >/dev/null

echo "preprovision: FOUNDRY_ACCOUNT_NAME=$account, FOUNDRY_PROJECT_NAME=$project"

# Self-heal: see preprovision.ps1 comment for context.
case "${HOSTED_AGENT_NAME:-}" in
    *-windows|*-linux|*-pricing)
        echo "preprovision: detected legacy HOSTED_AGENT_NAME='$HOSTED_AGENT_NAME' (suffixed) — resetting to 'vmagent-agent'"
        azd env set HOSTED_AGENT_NAME 'vmagent-agent' >/dev/null
        export HOSTED_AGENT_NAME='vmagent-agent'
        for k in HOSTED_AGENT_NAME_WINDOWS HOSTED_AGENT_NAME_LINUX HOSTED_AGENT_NAME_PRICING; do
            if [ -n "$(printenv "$k" || true)" ]; then
                azd env set "$k" '' >/dev/null
                unset "$k"
            fi
        done
        ;;
esac

# Ensure the Foundry account has its 'agents' capability host. Required
# before any hosted agent can be created. Idempotent: PUT is a no-op if
# already provisioned. Takes ~3-4 min on first create.
sub_id=$(az account show --query id -o tsv)
api_version='2025-10-01-preview'
cap_host_uri="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${FOUNDRY_RG}/providers/Microsoft.CognitiveServices/accounts/${account}/capabilityHosts/agents?api-version=${api_version}"

state=$(az rest --method get --uri "$cap_host_uri" --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
if [ "$state" = "Succeeded" ]; then
    echo "preprovision: capability host 'agents' already provisioned (state=$state)"
else
    echo "preprovision: provisioning capability host 'agents' on Foundry account $account (this can take ~3-4 minutes)"
    body_file=$(mktemp)
    printf '{ "properties": { "capabilityHostKind": "Agents" } }' > "$body_file"
    az rest --method put --uri "$cap_host_uri" --headers "Content-Type=application/json" --body "@$body_file" >/dev/null
    rc=$?
    rm -f "$body_file"
    if [ $rc -ne 0 ]; then
        echo "Failed to PUT capability host on $account" 1>&2
        exit 1
    fi
    for i in $(seq 1 60); do
        sleep 10
        state=$(az rest --method get --uri "$cap_host_uri" --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
        echo "preprovision: capability host state=$state"
        if [ "$state" = "Succeeded" ]; then break; fi
        if [ "$state" = "Failed" ] || [ "$state" = "Canceled" ]; then
            echo "Capability host provisioning ended in state $state" 1>&2
            exit 1
        fi
    done
    if [ "$state" != "Succeeded" ]; then
        echo "Capability host did not reach Succeeded after 10 minutes (last state=$state)" 1>&2
        exit 1
    fi
fi
