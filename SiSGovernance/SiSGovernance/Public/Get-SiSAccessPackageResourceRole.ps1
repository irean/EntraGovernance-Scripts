function Get-SiSAccessPackageResourceRole {
    <#
    .SYNOPSIS
        Lists the roles a resource offers in a catalog - so you know what to pass
        as -RoleName to Add-SiSAccessPackageResource for applications and SharePoint
        sites, where role names aren't known in advance.

    .PARAMETER GroupId
        Entra group ObjectId. (ParameterSet 'Group')

    .PARAMETER ApplicationId
        ObjectId of the application's service principal (Enterprise application),
        not the app registration's appId. (ParameterSet 'Application')

    .PARAMETER SiteUrl
        SharePoint Online site URL. (ParameterSet 'SharePoint')

    .PARAMETER CatalogName
        Catalog display name. Specify this or -CatalogId.

    .PARAMETER CatalogId
        Catalog ObjectId. Specify this or -CatalogName.

    .PARAMETER AddToCatalog
        If the resource isn't in the catalog yet, add it (roles are only visible
        once it is). Without it, nothing is changed.

    .PARAMETER WhatIf
        With -AddToCatalog: shows that the resource would be added to the catalog,
        without adding it.

    .PARAMETER Confirm
        With -AddToCatalog: asks before adding the resource to the catalog.

    .EXAMPLE
        Get-SiSAccessPackageResourceRole -ApplicationId $sapSpId -CatalogName "Identity - Employee"

    .EXAMPLE
        Get-SiSAccessPackageResourceRole -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -CatalogName "Identity - Employee" -AddToCatalog

    .OUTPUTS
        SiSGovernance.ResourceRole: Resource, ResourceType, RoleName, RoleOriginId, Description.

    .NOTES
        Required scopes: EntitlementManagement.Read.All (ReadWrite.All with -AddToCatalog)
    #>

    [OutputType('SiSGovernance.ResourceRole')]
    # Medium: -AddToCatalog only makes the resource available in the catalog,
    # nobody gets access from it - so no prompt by default, but -WhatIf works
    [CmdletBinding(DefaultParameterSetName = 'Group', SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [guid]$GroupId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Application')]
        [guid]$ApplicationId,

        [Parameter(Mandatory = $true, ParameterSetName = 'SharePoint')]
        [ValidatePattern('^https://')]
        [string]$SiteUrl,

        [Parameter(Mandatory = $false)]
        [string]$CatalogName,

        [Parameter(Mandatory = $false)]
        [Nullable[guid]]$CatalogId,

        [Parameter(Mandatory = $false)]
        [switch]$AddToCatalog
    )

    if ([bool]$CatalogName -eq [bool]$CatalogId) {
        Write-Error -Message "Specify exactly one of -CatalogName or -CatalogId." -Category InvalidArgument
        return
    }

    $scope = if ($AddToCatalog) { 'EntitlementManagement.ReadWrite.All' } else { 'EntitlementManagement.Read.All' }
    if (-not (Confirm-GraphConnection -Scopes $scope)) { return }

    $catalog = Resolve-AccessPackageCatalog -CatalogId $(if ($CatalogId) { $CatalogId.ToString('D') }) -CatalogName $CatalogName
    if (-not $catalog) { return }

    $spec = ConvertTo-AccessPackageResourceSpec -Type $PSCmdlet.ParameterSetName `
        -GroupId $(if ($GroupId) { $GroupId.ToString('D') }) -ApplicationId $(if ($ApplicationId) { $ApplicationId.ToString('D') }) -SiteUrl $SiteUrl

    Write-Host "`n--- RESOURCE ROLES ---" -ForegroundColor Cyan
    $lookup = Get-CatalogResource -CatalogId $catalog.id -Spec $spec
    if (-not $lookup.Resource -and $AddToCatalog) {
        if (-not $PSCmdlet.ShouldProcess("$($spec.Type) $($spec.OriginId)", "Add to catalog '$($catalog.displayName)'")) { return }
        $lookup = Get-CatalogResource -CatalogId $catalog.id -Spec $spec -AddIfMissing
    }
    if ($lookup.Error) {
        $hint = if (-not $AddToCatalog) { ' Roles are only visible once the resource is in the catalog - re-run with -AddToCatalog, or let Add-SiSAccessPackageResource add it.' }
        Write-Error -Message "$($lookup.Error).$hint" -Category ObjectNotFound -TargetObject $spec.OriginId
        return
    }
    if ($lookup.AddedToCatalog) {
        Write-Host "Added to catalog '$($catalog.displayName)': $($lookup.Resource.displayName)" -ForegroundColor Green
    }
    Write-Host "Resource: $($lookup.Resource.displayName) ($($spec.Type))" -ForegroundColor Green

    $lookup.Roles | Sort-Object displayName | ForEach-Object {
        [PSCustomObject]@{
            PSTypeName   = 'SiSGovernance.ResourceRole'
            Resource     = $lookup.Resource.displayName
            ResourceType = $spec.Type
            RoleName     = $_.displayName
            RoleOriginId = $_.originId
            Description  = $_.description
        }
    }
}
