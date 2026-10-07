function Find-AccessPackageResourceRole {
    <#
    .SYNOPSIS
        Picks the requested role from a resource's roles, or explains why not.
    .NOTES
        Internal helper.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Spec,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Roles
    )

    $match = if ($Spec.RoleOriginId) {
        @($Roles | Where-Object { $_.originId -eq $Spec.RoleOriginId })
    }
    else {
        # Application / SharePoint: match the role's display name or its originId
        @($Roles | Where-Object { $_.displayName -eq $Spec.RoleName -or $_.originId -eq $Spec.RoleName })
    }

    $available = (@($Roles | ForEach-Object { $_.displayName }) | Sort-Object -Unique) -join ', '
    if ($match.Count -eq 0) {
        return [PSCustomObject]@{ Role = $null; Error = "Role '$($Spec.RoleName)' not found. Available: $available" }
    }
    if ($match.Count -gt 1) {
        return [PSCustomObject]@{ Role = $null; Error = "Role '$($Spec.RoleName)' matches $($match.Count) roles - use the role's originId instead (see Get-SiSAccessPackageResourceRole)" }
    }
    return [PSCustomObject]@{ Role = $match[0]; Error = $null }
}
