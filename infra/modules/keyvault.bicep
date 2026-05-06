@description('Key Vault name (3-24 chars, alphanumeric and hyphens)')
param name string

@description('Location')
param location string = resourceGroup().location

@description('Tags')
param tags object = {}

@description('Tenant ID')
param tenantId string = subscription().tenantId

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

output id string = kv.id
output name string = kv.name
output vaultUri string = kv.properties.vaultUri
