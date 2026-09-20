[CmdletBinding()]
#Requires -Modules Az.Accounts, Az.Resources, Microsoft.Graph.Authentication, ExchangeOnlineManagement

<#
.SYNOPSIS
    All-in-one script to set up the solution in your environment.
    Start by editing bicep\main.bicepparam and replace the example
    values with your values

.DESCRIPTION

.PARAMETER SubscriptionId
.PARAMETER ResourceGroup
.PARAMETER AccessPackageCatalogId
.PARAMETER EntitlementManagementRoleName
    Default: "Access package assignment manager".
.PARAMETER CustomExtensionDisplayName
.PARAMETER CustomExtensionDescription
.PARAMETER TenantId
.PARAMETER AppId
.PARAMETER CertificateThumbprint
    Optional Service Principal auth. Omit all three for interactive login.

.EXAMPLE
    .\Complete-EntitlementManagementSetup.ps1 `
        -SubscriptionId "<subscription-id>" -ResourceGroup "<resource-group>" `
        -AccessPackageCatalogId "<catalog-id>"  `
        -Organization "<yourdomain.onmicrosoft.com>"
#>
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$AccessPackageCatalogId,
    [Parameter()][string]$EntitlementManagementRoleName = "Access package assignment manager",
    # Built-in role template ID for "AccessPackage assignment manager" - a
    # fixed, documented GUID that is identical across every tenant (same
    # pattern as Entra's built-in directory role template IDs), so matching
    # on this instead of the displayName string sidesteps any portal-vs-Graph
    # naming/localization mismatch entirely.
    [Parameter()][string]
    $EntitlementManagementRoleTemplateId = "e2182095-804a-4656-ae11-64734e9b7ae5",
    [Parameter()][string]
    $CustomExtensionDisplayName = "Distribution List Membership Extension",
    [Parameter()][string]
    $CustomExtensionDescription = "Adds/removes Exchange Online distribution list membership for access package assignments and removals",

    [Parameter()][string]$TenantId,
    [Parameter()][string]$AppId,
    [Parameter()][string]$CertificateThumbprint,

    [Parameter()][string]$CustomRoleName = "DistributionListMembershipOnly"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    [ERR] $m" -ForegroundColor Red }

Write-Step "Validating bicep parameters"
$bicepParamPath = Join-Path $PSScriptRoot -ChildPath 'bicep' -AdditionalChildPath 'main.bicepparam'
$bicepPath = Join-Path $PSScriptRoot -ChildPath 'bicep' -AdditionalChildPath 'main.bicep'

$bicep = Get-Content -Path $bicepParamPath
if ($bicep -match 'example' -or $bicep -match 'access package guid') {
    Write-Fail "Found sample values in bicep param file"
    return
}

# Test if bicep is installed
Write-Step "Checking if bicep is in path"
try {
    bicep version | Out-Null
    Write-Ok
}
catch {
    Write-Warn "Not found in path, checking user folder"
    $bicepExeFolderPath = Join-Path -Path $env:USERPROFILE -ChildPath '.Azure' `
        -AdditionalChildPath 'bin'
    $bicepExePath = Join-Path -Path $bicepExeFolderPath -ChildPath 'bicep.exe'
    if (Test-Path $bicepExePath) {
        Write-Ok "Found in $bicepExeFolderPath adding to path"
        $env:path = "$bicepExeFolderPath;$($env:path)"
    }
    else {
        Write-Fail "No bicep found"
        Write-Step "Install according to https://learn.microsoft.com/sv-se/azure/azure-resource-manager/bicep/install before rerunning script"
        return
    }
}

#region Authentication 

Write-Step "Authenticating against Azure Resource Manager"
if ($CertificateThumbprint -and $AppId -and $TenantId) {
    Connect-AzAccount -ServicePrincipal -TenantId $TenantId -ApplicationId $AppId `
        -CertificateThumbprint $CertificateThumbprint | Out-Null
    Write-Ok "Authenticated via Service Principal with certificate"
}
else {
    $connectParams = @{ SubscriptionId = $SubscriptionId }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-AzAccount @connectParams | Out-Null
    Write-Ok "Authenticated interactively"
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
if (-not $TenantId) { $TenantId = (Get-AzContext).Tenant.Id }
Write-Ok "Subscription set: $SubscriptionId (tenant $TenantId)"

Write-Step "Authenticating against Microsoft Graph"

if ($CertificateThumbprint -and $AppId -and $TenantId) {
    Connect-MgGraph -ClientId $AppId -CertificateThumbprint $CertificateThumbprint `
        -TenantId $TenantId -NoWelcome | Out-Null
    Write-Ok "Graph connected via Service Principal with certificate"
}
else {
    Connect-MgGraph -Scopes "EntitlementManagement.ReadWrite.All", "RoleManagement.ReadWrite.Directory" `
        -TenantId $TenantId -NoWelcome | Out-Null
    Write-Ok "Graph connected (delegated, explicit scopes)"
}
Write-Step "Connecting to Exchange Online (interactive - use an account with Organization Management / Exchange Administrator rights)"
Connect-ExchangeOnline -Organization $Organization -ShowBanner:$false | Out-Null
Write-Ok "Connected"

#endregion

Write-Step "Starting bicep deploy"
$bicepResults = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup `
    -TemplateFile $bicepPath -TemplateParameterFile $bicepParamPath

if ($bicepResults.ProvisioningState -notmatch 'Succeeded') {
    Write-Fail "Bicep deployment failed"
    return
}

Write-Ok


Write-Step "Deploying webapp"
$FunctionAppName = $bicepResults.Outputs['functionAppName'].Value
Compress-Archive -Path .\function-distributionlist-membership\* -DestinationPath .\functionapp.zip -Force
Publish-AzWebApp -ResourceGroupName $ResourceGroup `
    -Name $FunctionAppName `
    -ArchivePath .\functionapp.zip -Force | Out-Null
Write-Ok "App published"

$LogicAppName = $bicepResults.Outputs['logicAppName'].Value

#region Grant the UAMI the catalog-scoped Entitlement Management role

Write-Step "Assigning '$EntitlementManagementRoleName' on catalog $AccessPackageCatalogId to the UAMI"

$allRoleDefs = (Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleDefinitions").value
$roleDef = $allRoleDefs | Where-Object { $_.id -eq $EntitlementManagementRoleTemplateId } |
Select-Object -First 1
if (-not $roleDef) {
    Write-Warn "Available role definitions: $(($allRoleDefs | ForEach-Object { "$($_.displayName) ($($_.id))" }) -join ', ')"
    Write-Fail "Role definition with template ID '$EntitlementManagementRoleTemplateId' ('$EntitlementManagementRoleName') not found under roleManagement/entitlementManagement/roleDefinitions."
}

try {
    Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/roleManagement/entitlementManagement/roleAssignments" `
        -Body (@{
            principalId      = $bicepResults.Outputs['uamiPrincipalId'].Value
            roleDefinitionId = $roleDef.id
            appScopeId       = "/AccessPackageCatalog/$AccessPackageCatalogId" 
        } | ConvertTo-Json) `
        -ContentType "application/json" | Out-Null
    Write-Ok "Entitlement management role assigned, scoped to this catalog only"
}
catch {
    if ($_ -match "already exist") { Write-Warn "Already assigned" } else { throw }
}

#endregion

#region Register the custom extension in Entra ID Governance

Write-Step "Registering custom extension '$CustomExtensionDisplayName' on catalog $AccessPackageCatalogId"

$extensionBody = @{
    "@odata.type"               = "#microsoft.graph.accessPackageAssignmentRequestWorkflowExtension"
    displayName                 = $CustomExtensionDisplayName
    description                 = $CustomExtensionDescription
    endpointConfiguration       = @{
        "@odata.type"        = "#microsoft.graph.logicAppTriggerEndpointConfiguration"
        subscriptionId       = $SubscriptionId
        resourceGroupName    = $ResourceGroup
        logicAppWorkflowName = $LogicAppName
    }
    authenticationConfiguration = @{ "@odata.type" = "#microsoft.graph.azureAdPopTokenAuthentication" }
} | ConvertTo-Json -Depth 10

$existingExtension = (Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/$AccessPackageCatalogId/customWorkflowExtensions?`$filter=displayName eq '$CustomExtensionDisplayName'").value |
Select-Object -First 1

if ($existingExtension) {
    Invoke-MgGraphRequest -Method PUT `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/$AccessPackageCatalogId/customWorkflowExtensions/$($existingExtension.id)" `
        -Body $extensionBody -ContentType "application/json" | Out-Null
    $extensionId = $existingExtension.id
    Write-Ok "Extension updated: $extensionId"
}
else {
    $response = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/$AccessPackageCatalogId/customWorkflowExtensions" `
        -Body $extensionBody -ContentType "application/json"
    $extensionId = $response.id
    Write-Ok "Extension registered: $extensionId"
}

#endregion

#region Register the managed identity as an Exchange Online service principal

Write-Step "Registering the managed identity as an Exchange Online service principal"
$ManagedIdentityAppId = $bicepResults.Outputs['exchangeRightsUamiClientId'].Value
$ServicePrincipalDisplayName =$bicepResults.Outputs['exchangeRightsUamiName'].Value  
$ManagedIdentityResourceId = $bicepResults.Outputs['exchangeRightsUamiPrincipalId'].Value
$sp = Get-ServicePrincipal -Identity $ManagedIdentityAppId -ErrorAction SilentlyContinue
if (-not $sp) {
    $sp = New-ServicePrincipal `
        -AppId $ManagedIdentityAppId `
        -ObjectId $ManagedIdentityResourceId `
        -DisplayName $ServicePrincipalDisplayName
    Write-Ok "Registered: $($sp.DisplayName) ($($sp.AppId))"
}
else {
    Write-Ok "Already registered: $($sp.DisplayName) ($($sp.AppId))"
}

#endregion

#region Create (or reuse) the least-privilege custom role, unless using the built-in one

Write-Step "Creating/reusing custom least-privilege role '$CustomRoleName'"
$existingRole = Get-ManagementRole -Identity $CustomRoleName -ErrorAction SilentlyContinue
if (-not $existingRole) {
    New-ManagementRole -Name $CustomRoleName -Parent "Mail Recipients" | Out-Null
    Write-Ok "Created '$CustomRoleName' as a copy of 'Mail Recipients'"

    $keepEntries = @(
        'Add-DistributionGroupMember',
        'Remove-DistributionGroupMember',
        'Get-DistributionGroupMember',
        'Get-DistributionGroup'
    )
    Get-ManagementRoleEntry "$CustomRoleName\*" |
    Where-Object { $_.Name -notin $keepEntries } |
    ForEach-Object { Remove-ManagementRoleEntry "$CustomRoleName\$($_.Name)" -Confirm:$false }
    Write-Ok "Trimmed '$CustomRoleName' down to: $($keepEntries -join ', ')"
}
else {
    Write-Ok "'$CustomRoleName' already exists - reusing it as-is (not re-trimming, in case you customized it, e.g. to add mailbox permission cmdlets for a different Function sharing this identity)"
}
$roleToAssign = $CustomRoleName

#endregion

#region Assign the role to the service principal

Write-Step "Assigning role '$roleToAssign' to $ServicePrincipalDisplayName"
$existingAssignment = Get-ManagementRoleAssignment -RoleAssignee $sp.Identity -Role $roleToAssign -ErrorAction SilentlyContinue
if (-not $existingAssignment) {
        New-ManagementRoleAssignment -Role $roleToAssign -App $ManagedIdentityAppId | Out-Null
        Write-Ok "Role assigned"
} else {
    Write-Ok "Already assigned"
}

#endregion

#region Summary
# Write results from bicep, will be displayed at the end of the script
$bicepResults.Outputs.Keys | 
Select-Object @{L = 'key'; E = { $_ } }, @{L = 'Value'; E = { $bicepResults.outputs[$_].Value } } |
Format-Table 

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Logic App:            $($bicepResults.Outputs['logicAppResourceId'].Value)" -ForegroundColor Green
Write-Host "  Custom extension:     $extensionId" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

#endregion