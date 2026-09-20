metadata description = '''Classic Windows Consumption Function App (PowerShell) for
DistributionListMembership, with a separate Exchange Online UAMI and Easy Auth.
This version uses the classic Y1/Dynamic Consumption plan and does not use
Flex Consumption functionAppConfig.'''

@description('Name of the Function App Azure resource.')
param functionAppName string

@description('Azure region.')
param location string

@description('''Name of the deployment storage account.
Must be globally unique, 3-24 chars, lowercase letters/numbers only.''')
param storageAccountName string = toLower('stfn${uniqueString(resourceGroup().id, functionAppName)}')

@description('Name of the classic Consumption App Service Plan.')
param appServicePlanName string = 'plan-${functionAppName}'

@description('PowerShell runtime version.')
param powerShellVersion string = '7.6'

@description('Resource ID of the separate UAMI that carries Exchange Online rights.')
param exchangeRightsUamiResourceId string

@description('''Client ID of the separate UAMI that carries Exchange Online rights.
Required by ExchangeOnline to connect using a UAMI instead of a system managed identity''')
param exchangeRightsUamiClientId string

@description('The Function App Registration appId. Used by Easy Auth as client ID and allowed audience.')
param functionAppRegistrationAppId string

@description('''Client ID (Application ID), not object/principal ID,
of the Logic Apps UAMI allowed to call this Function.''')
param callerUamiClientId string

@description('Exchange online organization to connect to')
param exchangeOnlineOrganization string

// ---------------------------------------------------------------------------
// Storage required by classic Consumption
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false

    allowSharedKeyAccess: true
  }
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'

// ---------------------------------------------------------------------------
// Classic Consumption plan
// ---------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
    size: 'Y1'
    family: 'Y'
    capacity: 0
  }
  kind: 'functionapp'
}

// ---------------------------------------------------------------------------
// Function App
// ---------------------------------------------------------------------------

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'

  identity: {
    // System assigned is used only for the functions own storage
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${exchangeRightsUamiResourceId}': {}
    }
  }

  properties: {
    serverFarmId: appServicePlan.id

    siteConfig: {
      alwaysOn: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      powerShellVersion: powerShellVersion

      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: storageConnectionString
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(replace('${functionAppName}-${uniqueString(resourceGroup().id, functionAppName)}', '_', ''))
        }
                {
          name: 'ExchangeOnlineOrganization'
          value: exchangeOnlineOrganization
        }
        {
          name: 'UamiClientId'
          value: exchangeRightsUamiClientId
        }
      ]
    }

    httpsOnly: true
  }
}

resource authSettings 'Microsoft.Web/sites/config@2022-09-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }

    identityProviders: {
      azureActiveDirectory: {
        enabled: true

        registration: {
          clientId: functionAppRegistrationAppId
          openIdIssuer: 'https://sts.windows.net/${subscription().tenantId}/'
        }

        validation: {
          allowedAudiences: [
            functionAppRegistrationAppId
          ]

          defaultAuthorizationPolicy: {
            allowedApplications: [
              callerUamiClientId
            ]
          }
        }
      }
    }
  }
}

output functionAppResourceId string = functionApp.id
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output functionAppSystemAssignedPrincipalId string = functionApp.identity.principalId
