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

@description('Hosted agent name (consumed by frontend env)')
param hostedAgentName string = '${namePrefix}-agent'

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

// containerapp-frontend, identity, rbac modules wired by later todos.

output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output TFSTATE_STORAGE_ACCOUNT_NAME string = tfstate.outputs.name
output TFSTATE_CONTAINER_NAME string = tfstate.outputs.tfstateContainerName
output KEYVAULT_NAME string = keyvault.outputs.name
output KEYVAULT_URI string = keyvault.outputs.vaultUri
output TARGET_SUBSCRIPTION_ID string = targetSubscriptionId
output FOUNDRY_PROJECT_ENDPOINT string = foundryProjectEndpoint
output HOSTED_AGENT_NAME string = hostedAgentName
