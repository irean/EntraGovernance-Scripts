function Get-AccessPackageResourceState {
    <#
    .SYNOPSIS
        Reads an access package with its catalog and its current resource role
        scopes (what it grants today).
    .NOTES
        Internal helper, used by Add-/Remove-SiSAccessPackageResource.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId
    )

    $baseUri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId"
    try {
        $package = Invoke-MgGraphRequest -Method GET -Uri "$baseUri`?`$expand=catalog" -ErrorAction Stop
        $withScopes = Invoke-MgGraphRequest -Method GET -Uri "$baseUri`?`$expand=resourceRoleScopes(`$expand=role,scope)" -ErrorAction Stop
    }
    catch {
        return [PSCustomObject]@{ Package = $null; Error = "Access package not found: $($_.Exception.Message)" }
    }

    return [PSCustomObject]@{
        Package            = $package
        CatalogId          = $package['catalog']['id']
        CatalogName        = $package['catalog']['displayName']
        ResourceRoleScopes = @($withScopes['resourceRoleScopes'] | Where-Object { $_ })
        Error              = $null
    }
}
