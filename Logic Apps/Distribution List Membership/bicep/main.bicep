metadata description = '''Distribution List membership solution - Bicep version.
Configures Logic app, function app and the User-Assigned Managed Identities required
for a working setup.'''

extension microsoftGraphV1

// ---------------------------------------------------------------------------
// Infra parameters
// ---------------------------------------------------------------------------

@description('Azure region for the UAMI and Logic App.')
param location string = 'swedencentral'

@description('Name of the Logic App (Consumption) resource.')
param logicAppName string = 'logic-distributionlist-membership'

@description('''Name of the shared User-Assigned Managed Identity used by Logic Apps.
If you already have  one for your existing logic apps, use that here.''')
param uamiName string = 'uami-gov-logicapps'

@description('''Name of a SEPARATE User-Assigned Managed Identity carrying only Exchange Online rights.
Deliberately not the same identity as uamiName above: this one is meant to be attached to one or more
Function Apps that need to run Exchange Online cmdlets (this solution's Function, and potentially others
later, e.g. a shared-mailbox-permissions Function), keeping "can call our Logic App / Graph" and
"can write to Exchange Online" as two separate, independently-scoped privileges - so a future Logic App reusing
uamiName never inherits Exchange Online rights just because it shares an identity with something that has them.''')
param exchangeRightsUamiName string = 'uami-gov-exchange-rights'

// ---------------------------------------------------------------------------
// Function App Registration parameters
// ---------------------------------------------------------------------------

@description('The app role "value" granted to the UAMI and validated by the Function.')
param functionAppRoleValue string = 'DistributionList.Manage'

// ---------------------------------------------------------------------------
// Function App infra parameters (modules/functionapp.bicep)
// ---------------------------------------------------------------------------

@description('''Name of the Function App Azure resource. Leave empty to stay at stage A
(identity/registration only - no Function App infra deployed).
If this matches a Function App you already created manually, Bicep adopts/updates it in place
instead of duplicating it. Setting this also deploys its storage account and its
Easy Auth (authsettingsV2) configuration declaratively, and auto-computes -functionUri below unless
you override it. Deploys a Windows Consumption (Y1) plan - see modules/functionapp.bicep\'s metadata
for why (plain Az PowerShell code deployment via Publish-AzWebApp,
which Flex Consumption does not support).''')
param functionAppName string

@description('PowerShell runtime version for the Function App. Only used when functionAppName is set.')
param powerShellVersion string = '7.6'

// ---------------------------------------------------------------------------
// Logic App 
// ---------------------------------------------------------------------------

@description('''Id of the Entra ID Governance Access Package Catalog this solution reacts to.
Also used by the companion PowerShell script to scope the Entitlement Management role assignment.''')
param accessPackageCatalogId string

@description('''Maps an Access Package Id to the array of distribution list SMTP addresses that
should be added/removed for it. Required from stage B onwards (once -functionUri is set) -
the Logic App will simply match nothing if this is left at its empty default while functionUri is
set, so fill this in via your parameter file before that point.''')
param distributionListMapping object = {}

@description('''Full HTTPS URL of the deployed DistributionListMembership function,
e.g. https://<your-function-app>.azurewebsites.net/api/DistributionListMembership.
Leave empty to auto-compute this from functionAppName above (recommended) - only set it explicitly
if you are pointing at a Function App this template does not manage.''')
param functionUri string = ''

@description('Free-text \'source\' value sent in the best-effort status report back to Microsoft Graph. Purely cosmetic.')
param callbackSourceName string = 'CustomExtension.DistributionListProvisioning'

@description('''The appid claim of the Entra ID Governance calling identity,
for the AADPOP trigger policy. ''')
param governanceCallerAppId string = '810dcf14-1858-4bf2-8134-4c369fa3235b'

@description('Exchange online organization function app connects to')
param exchangeOnlineOrganization string

// ---------------------------------------------------------------------------
// Resources - always deployed (stage A onwards)
// ---------------------------------------------------------------------------

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// Separate identity, on purpose - see the parameter description above.
// Not attached to anything by this template
resource exchangeRightsUami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: exchangeRightsUamiName
  location: location
}
var functionAppRoleId = guid(resourceGroup().id, functionAppName, functionAppRoleValue)

// Configure the application registration for the function app
resource fnApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: functionAppName
  displayName: functionAppName
  appRoles: [
    {
      id: functionAppRoleId
      allowedMemberTypes: [
        'Application'
      ]
      description: 'Allows adding/removing members of specific Exchange Online distribution lists.'
      displayName: 'Manage Distribution List Membership'
      value: functionAppRoleValue
      isEnabled: true
    }
  ]
}


// Create a service principal linked to the application registration above
resource fnSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: fnApp.appId
  appRoleAssignmentRequired: true
}

// Assign the app role to the logic app uami to allow it to call the function app
resource uamiAppRoleAssignment 'Microsoft.Graph/appRoleAssignedTo@v1.0' = {
  appRoleId: functionAppRoleId
  principalId: uami.properties.principalId
  resourceId: fnSp.id
}

module functionAppModule 'modules/functionapp.bicep' = {
  name: 'dl-membership-functionapp'
  params: {
    functionAppName: functionAppName
    location: location
    exchangeRightsUamiResourceId: exchangeRightsUami.id
    exchangeRightsUamiClientId: exchangeRightsUami.properties.clientId
    functionAppRegistrationAppId: fnApp.appId
    callerUamiClientId: uami.properties.clientId
    powerShellVersion: powerShellVersion
    exchangeOnlineOrganization: exchangeOnlineOrganization
  }
}

// Auto-computed from the Function App this template just deployed, unless
// you explicitly overrode -functionUri (e.g. to point at a Function App this
// template doesn't manage).
var effectiveFunctionUri = !empty(functionUri)
  ? functionUri
  : 'https://${functionAppModule.?outputs.functionAppDefaultHostName ?? ''}/api/DistributionListMembership'


// The if-condition itself must be calculable before deployment starts, so it
// can only reference parameters/variables that don't depend on another
// module's runtime output - it cannot reference effectiveFunctionUri
// directly (Bicep error BCP177). Whether the Logic App should deploy is
// fully determined by the two parameters anyway: either functionUri was
// given explicitly, or functionAppName was given (which is what makes
// effectiveFunctionUri non-empty in the first place).
module logicApp 'modules/logicapp.bicep' = if (!empty(functionUri) || !empty(functionAppName)) {
  name: 'dl-membership-logicapp'
  params: {
    logicAppName: logicAppName
    location: location
    userAssignedIdentityResourceId: uami.id
    accessPackageCatalogId: accessPackageCatalogId
    distributionListMapping: distributionListMapping
    functionUri: effectiveFunctionUri
    // We deliberately use the raw application (client) ID as the audience
    // rather than a custom App ID URI (api://<appId>): setting identifierUris
    // to a value derived from the app's own appId would be a self-reference
    // the Graph Bicep extension can't express in one pass (create, then patch
    // identifierUris, is a two-phase operation - fine in imperative script,
    // not in a single declarative resource). A bare appId is a perfectly
    // valid audience/resource identifier for an Azure AD app that exposes no
    // custom scopes, which is exactly our case (app-role-only, no user-facing
    // API surface). Configure the Function App's Easy Auth "Allowed token
    // audiences" to include this same value.
    functionAudience: fnApp.appId
    callbackSourceName: callbackSourceName
    governanceCallerAppId: governanceCallerAppId
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output uamiPrincipalId string = uami.properties.principalId
output uamiResourceId string = uami.id
output uamiClientId string = uami.properties.clientId
output exchangeRightsUamiResourceId string = exchangeRightsUami.id
output exchangeRightsUamiClientId string = exchangeRightsUami.properties.clientId
output exchangeRightsUamiPrincipalId string = exchangeRightsUami.properties.principalId
output exchangeRightsUamiObjectId string = exchangeRightsUami.id
output exchangeRightsUamiName string = exchangeRightsUamiName
output functionAppRegistrationAppId string = fnApp.appId
output functionAppRoleId string = functionAppRoleId
output functionAudience string = fnApp.appId
output functionAppDefaultHostName string = functionAppModule.?outputs.functionAppDefaultHostName ?? ''
output effectiveFunctionUri string = effectiveFunctionUri
output logicAppResourceId string = logicApp.?outputs.logicAppResourceId ?? ''
output logicAppName string = logicAppName
output functionAppName string = functionAppName
