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

echo "postprovision: complete. Run 'azd deploy' to push the frontend image."
