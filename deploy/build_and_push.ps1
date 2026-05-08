# Build & push the agent image to ACR (uses the registry's build service).
# Requires: az login.
param(
    [string]$Registry = "vmagentacrrba7ch",
    [string]$Image = "vmagent-agent",
    [string]$Tag = "0.1.0",
    [string]$AgentDir = "$PSScriptRoot/../agent"
)

$ErrorActionPreference = "Stop"

$ref = "$Image" + ":" + "$Tag"
Write-Host "Building $Registry/$ref from $AgentDir"

az acr build `
    --registry $Registry `
    --image $ref `
    --file "$AgentDir/Dockerfile" `
    $AgentDir

Write-Host "Pushed: $Registry.azurecr.io/$ref"
