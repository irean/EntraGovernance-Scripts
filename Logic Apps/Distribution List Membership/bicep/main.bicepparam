using 'main.bicep'

// Azure region to deploy to
param location = 'example'
// Access package catalog to configure the custom extension in
param accessPackageCatalogId = 'example guid'

param exchangeOnlineOrganization = 'example.onmicrosoft.com'

param functionAppName = 'func-gov-distributionlist-membership-example'

// Remember to configure this before running a deployment
param distributionListMapping = {
  'access package guid': [
    'dl1@example.com'
    'dl2@example.com'
  ]
}
