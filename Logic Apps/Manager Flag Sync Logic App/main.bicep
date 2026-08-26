@description('Name of the Logic App (workflow) resource to create or update.')
param logicAppName string

@description('Azure region for the Logic App resource.')
param location string = resourceGroup().location

@description('Full resource ID of the user-assigned managed identity the workflow should use to call Microsoft Graph, e.g. /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<identity-name>. This identity is both assigned to the Logic App resource and referenced by every HTTP action\'s authentication block.')
param managedIdentityResourceId string

@description('The FULL directory extension attribute name used to flag a user as a manager, e.g. extension_<extension-app-id-without-dashes>_idg_isManager. Must already exist in the tenant - this template does not create it.')
param isManagerAttributeName string

@description('The FULL directory extension attribute name used to store the manager\'s scope (National/International), e.g. extension_<extension-app-id-without-dashes>_idg_managementScope. Must already exist in the tenant - this template does not create it.')
param managementScopeAttributeName string

@description('Base URL for Microsoft Graph. Only change this for a national/sovereign cloud Graph endpoint.')
param graphBaseUrl string = 'https://graph.microsoft.com'

@description('Audience used when the managed identity requests a token for Graph. Usually matches graphBaseUrl, but can differ for sovereign clouds.')
param graphAudience string = 'https://graph.microsoft.com'

@description('employeeType values that count as direct reports worth evaluating for manager status.')
param includedEmployeeTypes array = [
  'Employee'
  'Subcontractor'
]

@description('Recurrence interval for the trigger, combined with recurrenceFrequency.')
param recurrenceInterval int = 1

@description('Recurrence frequency for the trigger, e.g. Day, Hour, Week.')
param recurrenceFrequency string = 'Day'

@description('Hour(s) of day the recurrence should fire, used when recurrenceFrequency is Day.')
param recurrenceHours array = [
  2
]

resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityResourceId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    definition: loadJsonContent('workflow.definition.json')
    parameters: {
      '$connections': {
        value: {}
      }
      graphBaseUrl: {
        value: graphBaseUrl
      }
      graphAudience: {
        value: graphAudience
      }
      managedIdentityResourceId: {
        value: managedIdentityResourceId
      }
      isManagerAttributeName: {
        value: isManagerAttributeName
      }
      managementScopeAttributeName: {
        value: managementScopeAttributeName
      }
      includedEmployeeTypes: {
        value: includedEmployeeTypes
      }
      recurrenceInterval: {
        value: recurrenceInterval
      }
      recurrenceFrequency: {
        value: recurrenceFrequency
      }
      recurrenceHours: {
        value: recurrenceHours
      }
    }
  }
}

output logicAppResourceId string = logicApp.id
