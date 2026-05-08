#!/usr/bin/env sh
# Validates env vars required by the postprovision hook + deploy_all.py.
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
