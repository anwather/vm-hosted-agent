targetScope = 'resourceGroup'

@description('Short prefix for resource names (3-10 lowercase alphanumeric)')
@minLength(3)
@maxLength(10)
param namePrefix string = 'vmagent'

@description('Azure region for new resources')
param location string = resourceGroup().location

@description('Target subscription where the agent will deploy VMs')
param targetSubscriptionId string

@description('Foundry project endpoint (consumed by frontend env)')
param foundryProjectEndpoint string

@description('Hosted agent name (consumed by frontend env, Windows default)')
param hostedAgentName string = '${namePrefix}-agent'

@description('Persistent orchestrator agent name')
param orchestratorAgentName string = 'taskorch-orchestrator'

@description('Hosted Windows VM agent name')
param hostedAgentNameWindows string = '${hostedAgentName}-windows'

@description('Hosted Linux VM agent name')
param hostedAgentNameLinux string = '${hostedAgentName}-linux'

@description('Hosted pricing agent name (third agent, same image, different role).')
param hostedAgentNamePricing string = '${hostedAgentName}-pricing'

@description('Frontend image version label (shown in footer)')
param frontendVersion string = '0.5.1'

var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, namePrefix))
var shortToken = substring(resourceToken, 0, 6)

var tags = {
  'azd-env-name': namePrefix
  workload: 'vm-hosted-agent'
}

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: '${namePrefix}acr${shortToken}'
    location: location
    tags: tags
  }
}

module tfstate 'modules/storage-tfstate.bicep' = {
  name: 'tfstate'
  params: {
    name: '${namePrefix}st${shortToken}'
    location: location
    tags: tags
  }
}

module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    name: '${namePrefix}kv${shortToken}'
    location: location
    tags: tags
  }
}

// ============================================================
// Frontend stack: UAMI + AcrPull + Container App Environment + Container App
// ============================================================

module frontendIdentity 'modules/identity.bicep' = {
  name: 'frontend-identity'
  params: {
    name: '${namePrefix}-frontend-mi'
    location: location
    tags: tags
  }
}

module acrPull 'modules/rbac-acrpull.bicep' = {
  name: 'frontend-acrpull'
  params: {
    acrName: acr.outputs.name
    principalId: frontendIdentity.outputs.principalId
  }
}

module frontend 'modules/containerapp-frontend.bicep' = {
  name: 'frontend'
  dependsOn: [ acrPull ]
  params: {
    envName: '${namePrefix}-cae'
    appName: '${namePrefix}-frontend'
    location: location
    tags: tags
    userAssignedIdentityId: frontendIdentity.outputs.id
    userAssignedIdentityClientId: frontendIdentity.outputs.clientId
    acrLoginServer: acr.outputs.loginServer
    foundryProjectEndpoint: foundryProjectEndpoint
    hostedAgentName: hostedAgentName
    orchestratorAgentName: orchestratorAgentName
    hostedAgentNameWindows: hostedAgentNameWindows
    hostedAgentNameLinux: hostedAgentNameLinux
    hostedAgentNamePricing: hostedAgentNamePricing
    frontendVersion: frontendVersion
  }
}

output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output TFSTATE_STORAGE_ACCOUNT_NAME string = tfstate.outputs.name
output TFSTATE_CONTAINER_NAME string = tfstate.outputs.tfstateContainerName
output KEYVAULT_NAME string = keyvault.outputs.name
output KEYVAULT_URI string = keyvault.outputs.vaultUri
output TARGET_SUBSCRIPTION_ID string = targetSubscriptionId
output FOUNDRY_PROJECT_ENDPOINT string = foundryProjectEndpoint
output HOSTED_AGENT_NAME string = hostedAgentName
output ORCHESTRATOR_AGENT_NAME string = orchestratorAgentName
output HOSTED_AGENT_NAME_WINDOWS string = hostedAgentNameWindows
output HOSTED_AGENT_NAME_LINUX string = hostedAgentNameLinux
output HOSTED_AGENT_NAME_PRICING string = hostedAgentNamePricing
output FRONTEND_IDENTITY_PRINCIPAL_ID string = frontendIdentity.outputs.principalId
output FRONTEND_IDENTITY_CLIENT_ID string = frontendIdentity.outputs.clientId
output FRONTEND_APP_NAME string = frontend.outputs.appName
output FRONTEND_FQDN string = frontend.outputs.appFqdn
