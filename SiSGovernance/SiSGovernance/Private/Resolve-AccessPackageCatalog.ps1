function Resolve-AccessPackageCatalog {
    <#
    .SYNOPSIS
        Resolves a catalog by id or by display name and returns {id, displayName},
        or writes an error and returns $null if it can't be found (or the name
        matches more than one catalog).
    .NOTES
        Internal helper, used by New-SiSAccessPackage.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CatalogId,

        [Parameter(Mandatory = $false)]
        [string]$CatalogName
    )

    Write-Host "`n--- CATALOG ---" -ForegroundColor Cyan

    if ($CatalogId -and -not (Test-IsGuid $CatalogId)) {
        Write-Error -Message "CatalogId '$CatalogId' is not a valid GUID." -Category InvalidArgument -TargetObject $CatalogId
        return $null
    }

    if ($CatalogId) {
        try {
            $catalog = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs/$CatalogId" `
                -ErrorAction Stop
        }
        catch {
            Write-Error -Message "Catalog $CatalogId not found - check the id and your permissions. $($_.Exception.Message)" -Category ObjectNotFound -TargetObject $CatalogId
            return $null
        }
        Write-Host "Catalog : $($catalog['displayName'])" -ForegroundColor Green
        return [PSCustomObject]@{ id = $catalog['id']; displayName = $catalog['displayName'] }
    }

    # Single quotes in the name need to be doubled for OData
    $safeName = $CatalogName -replace "'", "''"
    $uri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/catalogs?`$filter=displayName eq '$safeName'"

    try {
        $catalogs = @(Get-GraphPagedResult -Uri $uri)
    }
    catch {
        Write-Error -Message "Catalog lookup failed. $($_.Exception.Message)" -Category ReadError -TargetObject $CatalogName
        return $null
    }

    if ($catalogs.Count -eq 0) {
        Write-Error -Message "No catalog named '$CatalogName' was found." -Category ObjectNotFound -TargetObject $CatalogName
        return $null
    }
    if ($catalogs.Count -gt 1) {
        # displayName isn't unique in Entra - don't guess which one was meant
        Write-Error -Message "More than one catalog is named '$CatalogName' ($(($catalogs.id) -join ', ')). Re-run with -CatalogId instead." -Category InvalidArgument -TargetObject $CatalogName
        return $null
    }

    Write-Host "Catalog : $($catalogs[0].displayName)" -ForegroundColor Green
    return [PSCustomObject]@{ id = $catalogs[0].id; displayName = $catalogs[0].displayName }
}
