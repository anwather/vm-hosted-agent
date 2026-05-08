// Container App Environment + Frontend Container App (FastAPI + HTMX) with
// system-managed ACR pull via UAMI. Easy Auth (Entra) is enabled by a
// post-deploy `az containerapp auth` step (cannot be cleanly modeled in Bicep
// without an existing app registration); the bicep just opens external ingress.

@description('Container App Environment name')
param envName string
@description('Container App name (frontend)')
param appName string
@description('Azure region')
param location string
@description('Tags')
param tags object = {}

@description('UAMI resource id used for ACR pull and AI Project access')
param userAssignedIdentityId string
@description('UAMI clientId for AZURE_CLIENT_ID env var')
param userAssignedIdentityClientId string

@description('ACR login server (e.g. myacr.azurecr.io)')
param acrLoginServer string
@description('Container image (full reference, e.g. myacr.azurecr.io/vmagent-frontend:0.1.0). Use a placeholder for first deploy; azd will update on `azd deploy`.')
param image string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Foundry project endpoint passed to the frontend')
param foundryProjectEndpoint string
@description('Hosted agent name passed to the frontend (back-compat / Windows default)')
param hostedAgentName string
@description('Persistent orchestrator agent name (Task Orchestrator)')
param orchestratorAgentName string = 'taskorch-orchestrator'
@description('Hosted Windows VM agent name')
param hostedAgentNameWindows string = hostedAgentName
@description('Hosted Linux VM agent name')
param hostedAgentNameLinux string = '${hostedAgentName}-linux'
@description('Hosted pricing agent name')
param hostedAgentNamePricing string = '${hostedAgentName}-pricing'
@description('Frontend version label (shown in footer)')
param frontendVersion string = '0.4.3'

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${envName}-law'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    features: { searchVersion: 1 }
  }
}

resource cae 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: union(tags, { 'azd-service-name': 'frontend' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    environmentId: cae.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acrLoginServer
          identity: userAssignedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'frontend'
          image: image
          resources: { cpu: json('0.5'), memory: '1Gi' }
          env: [
            { name: 'FOUNDRY_PROJECT_ENDPOINT', value: foundryProjectEndpoint }
            { name: 'HOSTED_AGENT_NAME', value: hostedAgentName }
            { name: 'ORCHESTRATOR_AGENT_NAME', value: orchestratorAgentName }
            { name: 'HOSTED_AGENT_NAME_WINDOWS', value: hostedAgentNameWindows }
            { name: 'HOSTED_AGENT_NAME_LINUX', value: hostedAgentNameLinux }
            { name: 'HOSTED_AGENT_NAME_PRICING', value: hostedAgentNamePricing }
            { name: 'FRONTEND_VERSION', value: frontendVersion }
            { name: 'AZURE_CLIENT_ID', value: userAssignedIdentityClientId }
            { name: 'PORT', value: '8000' }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 3 }
    }
  }
}

output appName string = app.name
output appFqdn string = app.properties.configuration.ingress.fqdn
output environmentId string = cae.id
