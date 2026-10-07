function New-SiSAccessPackage {
    <#
    .SYNOPSIS
        Creates a new, empty Access Package in an Entitlement Management catalog.

    .DESCRIPTION
        Resolves the catalog (by id or name), checks that no access package with
        the same name already exists in that catalog, and creates the access
        package after confirmation.

        Only the package itself - resources are added with Add-SiSAccessPackageResource
        (groups, applications, SharePoint sites), which takes this function's
        output from the pipeline. No assignment policy is created.

    .PARAMETER DisplayName
        Name of the new access package.

    .PARAMETER Description
        Description shown to users in My Access.

    .PARAMETER CatalogId
        The ObjectId of the catalog. (ParameterSet 'CatalogId')

    .PARAMETER CatalogName
        Display name of the catalog. Stops if more than one catalog has that name. (ParameterSet 'CatalogName', default)

    .PARAMETER IsHidden
        Hides the access package from My Access - users need the direct link to request it.

    .PARAMETER WhatIf
        Runs the catalog lookup and duplicate check, shows what would be created, then stops.

    .PARAMETER Confirm
        Asks before creating (the default). -Confirm:$false creates without asking.

    .EXAMPLE
        # Preview first
        New-SiSAccessPackage -DisplayName "AP - Sales - Read" -Description "Read access for Sales" `
            -CatalogName "Sales" -WhatIf

    .EXAMPLE
        # Create it, and add a group in the same pipeline
        New-SiSAccessPackage -DisplayName "AP - Sales - Read" -Description "Read access for Sales" `
            -CatalogName "Sales" | Add-SiSAccessPackageResource -GroupId $groupId

    .OUTPUTS
        SiSGovernance.AccessPackage: Id, DisplayName, CatalogId, CatalogName, IsHidden.
        Id binds to Add-SiSAccessPackageResource -AccessPackageId through the pipeline.

    .NOTES
        Required scopes: EntitlementManagement.ReadWrite.All
        Least privileged role: Access package manager on the catalog (via PIM)
    #>

    [OutputType('SiSGovernance.AccessPackage')]
    [CmdletBinding(DefaultParameterSetName = 'CatalogName', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$Description,

        [Parameter(Mandatory = $true, ParameterSetName = 'CatalogId')]
        [Nullable[guid]]$CatalogId,

        [Parameter(Mandatory = $true, ParameterSetName = 'CatalogName')]
        [string]$CatalogName,

        [Parameter(Mandatory = $false)]
        [switch]$IsHidden
    )

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   NEW ACCESS PACKAGE   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    if (-not (Confirm-GraphConnection -Scopes 'EntitlementManagement.ReadWrite.All')) { return }

    $catalog = Resolve-AccessPackageCatalog -CatalogId $(if ($CatalogId) { $CatalogId.ToString('D') }) -CatalogName $CatalogName
    if (-not $catalog) { return }

    # Entra happily creates two access packages with the same name in the same
    # catalog, which is confusing for everyone afterwards - so stop here instead.
    Write-Host "`n--- DUPLICATE CHECK ---" -ForegroundColor Cyan
    $safeName = $DisplayName -replace "'", "''"
    $uri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages?`$filter=displayName eq '$safeName'&`$expand=catalog"
    try {
        $existing = @(Get-GraphPagedResult -Uri $uri) | Where-Object { $_.catalog.id -eq $catalog.id }
    }
    catch {
        Write-Error -Message "Could not check for existing access packages. $($_.Exception.Message)" -Category ReadError -TargetObject $DisplayName
        return
    }
    if ($existing) {
        Write-Error -Message "An access package named '$DisplayName' already exists in '$($catalog.displayName)' (id $(@($existing)[0].id))." -Category ResourceExists -TargetObject $DisplayName
        return
    }
    Write-Host "No existing access package with that name in this catalog." -ForegroundColor Green

    Write-Host "`n Create:" -ForegroundColor Yellow
    Write-Host "   Name        : $DisplayName" -ForegroundColor White
    Write-Host "   Description : $Description" -ForegroundColor White
    Write-Host "   Catalog     : $($catalog.displayName)" -ForegroundColor White
    Write-Host "   Hidden      : $($IsHidden.IsPresent)" -ForegroundColor White

    if (-not $PSCmdlet.ShouldProcess("'$DisplayName' in catalog '$($catalog.displayName)'", 'Create access package')) {
        if (-not $WhatIfPreference) { Write-Warning "Cancelled - no changes were made." }
        return
    }

    Write-Host "`n--- CREATE ACCESS PACKAGE ---" -ForegroundColor Cyan
    $body = @{
        displayName = $DisplayName
        description = $Description
        isHidden    = $IsHidden.IsPresent
        catalog     = @{ id = $catalog.id }
    } | ConvertTo-Json -Depth 5

    try {
        $accessPackage = Invoke-MgGraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages" `
            -Body $body -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        Write-Error -Message "Failed to create access package '$DisplayName'. $($_.Exception.Message)" -Category WriteError -TargetObject $DisplayName
        return
    }
    Write-Host "Access Package created: $($accessPackage['displayName'])" -ForegroundColor Green
    Write-Host "   Id: $($accessPackage['id'])" -ForegroundColor White

    Write-Host "`n==========================================" -ForegroundColor DarkGray
    Write-Host "   OPERATION COMPLETE" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   Remember: the access package has no resources and no assignment" -ForegroundColor Yellow
    Write-Host "   policy yet - add them with Add-SiSAccessPackageResource and a policy." -ForegroundColor Yellow

    return [PSCustomObject]@{
        PSTypeName  = 'SiSGovernance.AccessPackage'
        Id          = $accessPackage['id']
        DisplayName = $accessPackage['displayName']
        CatalogId   = $catalog.id
        CatalogName = $catalog.displayName
        IsHidden    = $IsHidden.IsPresent
    }
}
