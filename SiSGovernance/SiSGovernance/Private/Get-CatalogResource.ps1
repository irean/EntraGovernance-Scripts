function Get-CatalogResource {
    <#
    .SYNOPSIS
        Finds a resource (any type) in a catalog by originId, with its scopes and
        roles. With -AddIfMissing it's added to the catalog first and polled
        until it shows up.
    .NOTES
        Internal helper. A resource in a catalog can be shared by many access
        packages - this module never removes a resource from a catalog.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogId,

        [Parameter(Mandatory = $true)]
        [object]$Spec,

        [Parameter(Mandatory = $false)]
        [switch]$AddIfMissing,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 6
    )

    $baseUri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement"
    # originId can be a URL (SharePoint) - quote-escape for OData, then URL-encode
    $filterValue = [uri]::EscapeDataString(($Spec.OriginId -replace "'", "''"))
    $resourceUri = "$baseUri/catalogs/$CatalogId/resources?`$filter=originId eq '$filterValue'&`$expand=scopes"

    $findResource = {
        @(Get-GraphPagedResult -Uri $resourceUri | Where-Object { $_.id -and $_.originSystem -eq $Spec.OriginSystem }) | Select-Object -First 1
    }

    $resource = & $findResource
    $addedToCatalog = $false

    if (-not $resource -and $AddIfMissing) {
        $body = @{
            requestType = 'adminAdd'
            resource    = @{
                originId     = $Spec.OriginId
                originSystem = $Spec.OriginSystem
            }
            catalog     = @{ id = $CatalogId }
        } | ConvertTo-Json -Depth 5

        try {
            Invoke-MgGraphRequest -Method POST -Uri "$baseUri/resourceRequests" `
                -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $addedToCatalog = $true
        }
        catch {
            return [PSCustomObject]@{ Resource = $null; Roles = @(); AddedToCatalog = $false; Error = "Could not add resource to catalog: $($_.Exception.Message)" }
        }

        # The resource can take a few seconds to show up in the catalog
        $retries = 0
        do {
            Start-Sleep -Seconds ([Math]::Min(2 * [Math]::Pow(2, $retries), 30))
            $resource = & $findResource
            $retries++
        } while (-not $resource -and $retries -lt $MaxRetries)
    }

    if (-not $resource) {
        $msg = if ($AddIfMissing) { "Resource was requested into the catalog but didn't show up after $MaxRetries retries" } else { 'Resource is not in the catalog' }
        return [PSCustomObject]@{ Resource = $null; Roles = @(); AddedToCatalog = $addedToCatalog; Error = $msg }
    }

    # Roles via resourceRoles - the documented way for every resource type
    $rolesUri = "$baseUri/catalogs/$CatalogId/resourceRoles?`$filter=(originSystem eq '$($Spec.OriginSystem)' and resource/id eq '$($resource.id)')&`$expand=resource"
    $roles = @()
    $retries = 0
    do {
        try { $roles = @(Get-GraphPagedResult -Uri $rolesUri | Where-Object { $_.originId }) } catch { $roles = @() }
        if ($roles.Count -gt 0 -or -not $addedToCatalog) { break }
        Start-Sleep -Seconds 2
        $retries++
    } while ($retries -lt $MaxRetries)

    return [PSCustomObject]@{
        Resource       = $resource
        Roles          = $roles
        AddedToCatalog = $addedToCatalog
        Error          = $null
    }
}
