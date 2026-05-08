#!/usr/bin/env sh
# Runs after `azd provision`. POSIX twin of postprovision.ps1.
set -e

need() {
    name="$1"
    val=$(printenv "$name" || true)
    if [ -z "$val" ]; then
        echo "postprovision: env var $name is not set" 1>&2
        exit 1
    fi
    printf '%s' "$val"
}

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
acr=$(need AZURE_CONTAINER_REGISTRY_NAME)
rg=$(need AZURE_RESOURCE_GROUP)
tag="${AGENT_IMAGE_TAG:-latest}"
image_ref="$acr.azurecr.io/vmagent-agent:$tag"

echo "postprovision: building agent image $image_ref"
az acr build \
    --registry "$acr" \
    --image "vmagent-agent:$tag" \
    --file  "$repo_root/agent/Dockerfile" \
    "$repo_root/agent" \
    --no-logs

# Grant AcrPull on the new ACR to the Foundry project's system-assigned MI
# (or the account MI as fallback). Required before the first create_version
# or the agent provisioning fails with "Failed to pull container image".
foundry_rg=$(need FOUNDRY_RG)
foundry_acct=$(need FOUNDRY_ACCOUNT_NAME)
foundry_proj=$(need FOUNDRY_PROJECT_NAME)
sub_id="${VM_TARGET_SUBSCRIPTION_ID:-$(need AZURE_SUBSCRIPTION_ID)}"
proj_uri="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${foundry_rg}/providers/Microsoft.CognitiveServices/accounts/${foundry_acct}/projects/${foundry_proj}?api-version=2025-06-01"

echo "postprovision: fetching Foundry project system-assigned MI principalId"
proj_mi=$(az rest --method get --uri "$proj_uri" --query 'identity.principalId' -o tsv 2>/dev/null || true)
if [ -z "$proj_mi" ] || [ "$proj_mi" = "null" ]; then
    acct_uri="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${foundry_rg}/providers/Microsoft.CognitiveServices/accounts/${foundry_acct}?api-version=2025-06-01"
    proj_mi=$(az rest --method get --uri "$acct_uri" --query 'identity.principalId' -o tsv 2>/dev/null || true)
fi
if [ -z "$proj_mi" ] || [ "$proj_mi" = "null" ]; then
    echo "Could not resolve Foundry project/account system-assigned MI principalId. Ensure the Foundry account has a system-assigned identity enabled." 1>&2
    exit 1
fi

acr_id=$(az acr show -n "$acr" -g "$rg" --query id -o tsv)
if [ -z "$acr_id" ]; then echo "Could not resolve ACR id for $acr" 1>&2; exit 1; fi

echo "postprovision: granting AcrPull on $acr to Foundry MI $proj_mi"
az role assignment create \
    --assignee-object-id "$proj_mi" \
    --assignee-principal-type ServicePrincipal \
    --role 'AcrPull' \
    --scope "$acr_id" >/dev/null 2>&1 || true
echo "postprovision: waiting 60s for AcrPull RBAC propagation"
sleep 60

if [ -z "${KEYVAULT_NAME:-}" ] && [ -n "${KEYVAULT_URI:-}" ]; then
    derived=$(printf '%s' "$KEYVAULT_URI" | sed -nE 's#^https?://([^.]+)\.vault\.azure\.net/?$#\1#p')
    if [ -n "$derived" ]; then
        export KEYVAULT_NAME="$derived"
        azd env set KEYVAULT_NAME "$derived" >/dev/null
    fi
fi

export CONTAINER_IMAGE="$image_ref"
export TFSTATE_RESOURCE_GROUP="$rg"
export VM_TARGET_SUBSCRIPTION_ID="${VM_TARGET_SUBSCRIPTION_ID:-$(need AZURE_SUBSCRIPTION_ID)}"

echo "postprovision: ensuring deploy script dependencies"
python -m pip install -q -r "$repo_root/requirements-deploy.txt"

echo "postprovision: deploying orchestrator + 3 hosted agents to Foundry"
python "$repo_root/deploy/deploy_all.py"

if [ "${EASY_AUTH_ENABLED:-}" = "true" ]; then
    echo "postprovision: configuring Easy Auth (Entra SSO) on frontend container app"
    bash "$(dirname "$0")/easyauth.sh"
else
    echo "postprovision: Easy Auth disabled (set 'azd env set EASY_AUTH_ENABLED true' to enable)"
fi

echo "postprovision: complete. Run 'azd deploy' to push the frontend image."
