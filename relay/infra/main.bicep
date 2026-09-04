// Wingman relay infrastructure — resource-group scope (rg-forit-wingman).
//
// Creates the Function App and its plumbing. The Key Vault is declared `existing`: it was created
// once during bootstrap together with the two secrets it holds (anthropic-api-key,
// elevenlabs-api-key, both copied from the forit-ai-engine application settings — see
// .ai/decisions.md 001). This template never declares a secret value; the app reads them through
// Key Vault references resolved by its read-only managed identity.
//
// Deployed by .github/workflows/relay-deploy.yml with the "GitHub Actions - ForIT Wingman" OIDC
// identity (Contributor + Role Based Access Control Administrator on this resource group only).

targetScope = 'resourceGroup'

@description('Region for every resource. Defaults to the resource group region (eastus).')
param location string = resourceGroup().location

@description('Function App name. Also the hostname: <name>.azurewebsites.net')
param functionAppName string = 'forit-wingman-relay'

@description('Storage account for the Functions host. 3-24 lower-case alphanumerics, globally unique.')
param storageAccountName string = 'stforitwingmanrelay'

@description('Existing Key Vault holding anthropic-api-key and elevenlabs-api-key.')
param keyVaultName string = 'kv-forit-wingman'

@description('Entra tenant whose tokens the relay accepts.')
param entraTenantId string

@description('Application (client) id of the "ForIT Wingman" public client. id_tokens carry it as aud.')
param entraClientId string

@description('Comma-separated lower-case email domains allowed to use the relay (docs/PERMISSIONS.md 5.1).')
param allowedEmailDomains string = 'forit.io'

@description('Comma-separated model ids the desktop app may request.')
param allowedModels string = 'claude-sonnet-5,claude-opus-5'

@description('Model used when the app requests nothing or something not on the allow-list.')
param defaultModel string = 'claude-sonnet-5'

@description('ElevenLabs voice id. Empty disables /api/tts (the app then uses on-device speech).')
param elevenLabsVoiceId string = ''

@description('Git commit sha of the code being deployed; /api/health reports it.')
param relayVersion string

var tags = {
  product: 'wingman'
  component: 'relay'
  repo: 'ForITLLC/forit-Wingman'
}

// Key Vault Secrets User — read-only data-plane role for the managed identity.
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // the Functions host on a consumption plan still needs the key-based AzureWebJobsStorage
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-forit-wingman'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-forit-wingman-relay'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
  }
}

resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'plan-forit-wingman-relay'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true // Linux
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    reserved: true
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|22'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      // The desktop app is not a browser; no CORS origins are opened.
      cors: {
        allowedOrigins: []
      }
      appSettings: [
        { name: 'AzureWebJobsStorage', value: storageConnectionString }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'node' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: applicationInsights.properties.ConnectionString }
        { name: 'WINGMAN_ENTRA_TENANT_ID', value: entraTenantId }
        { name: 'WINGMAN_ENTRA_CLIENT_ID', value: entraClientId }
        { name: 'WINGMAN_ALLOWED_EMAIL_DOMAINS', value: allowedEmailDomains }
        { name: 'WINGMAN_MODEL_PROVIDER', value: 'anthropic' }
        { name: 'WINGMAN_ALLOWED_MODELS', value: allowedModels }
        { name: 'WINGMAN_DEFAULT_MODEL', value: defaultModel }
        { name: 'ELEVENLABS_VOICE_ID', value: elevenLabsVoiceId }
        { name: 'RELAY_VERSION', value: relayVersion }
        // Secrets: Key Vault references, resolved by the managed identity below. Never the value.
        { name: 'ANTHROPIC_API_KEY', value: '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/anthropic-api-key/)' }
        { name: 'ELEVENLABS_API_KEY', value: '@Microsoft.KeyVault(SecretUri=https://${keyVaultName}${environment().suffixes.keyvaultDns}/secrets/elevenlabs-api-key/)' }
      ]
    }
  }
}

// Read-only secret access for the Function App's identity on the product vault.
resource keyVaultSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, functionApp.id, 'kv-secrets-user')
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppHostName string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
