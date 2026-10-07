function Add-SiSAccessPackageResource {
    <#
    .SYNOPSIS
        Adds a role from a resource - an Entra group, an application or a
        SharePoint Online site - to one or more access packages.

    .DESCRIPTION
        Same flow for every resource type:
          1. reads each access package and what it already grants (nothing is changed yet)
          2. shows one preview and asks for confirmation once
          3. adds the resource to the package's catalog if it isn't there yet
          4. adds the role to the package

        A package that already has the role is reported as AlreadyAdded and left
        alone, so re-running is safe. Everyone already assigned to the package
        gets the new role.

        Accepts access packages from the pipeline (anything with an Id or
        AccessPackageId property, e.g. the output of New-SiSAccessPackage).

    .PARAMETER AccessPackageId
        One or more access package ObjectIds. Accepts pipeline input by property name (Id / AccessPackageId).

    .PARAMETER GroupId
        Entra group ObjectId. (ParameterSet 'Group', default)

    .PARAMETER Role
        Group role: Member (default) or Owner. (ParameterSet 'Group')

    .PARAMETER ApplicationId
        ObjectId of the application's service principal (Enterprise application),
        not the app registration's appId. (ParameterSet 'Application')

    .PARAMETER SiteUrl
        SharePoint Online site URL. (ParameterSet 'SharePoint')

    .PARAMETER RoleName
        For applications and SharePoint: the role's display name or originId.
        Use Get-SiSAccessPackageResourceRole to see what exists.

    .PARAMETER WhatIf
        Reads and shows what would change, then stops. Returns 'Preview - <action>'
        per package.

    .PARAMETER Confirm
        Asks before changing (the default). -Confirm:$false changes without asking.

    .EXAMPLE
        # New package with a group, in one go
        New-SiSAccessPackage -DisplayName "License - Baseline 5" -Description "..." -CatalogName "Identity - Employee" |
            Add-SiSAccessPackageResource -GroupId $licE5GroupId

    .EXAMPLE
        # App role
        Add-SiSAccessPackageResource -AccessPackageId $apId -ApplicationId $sapSpId -RoleName "User"

    .EXAMPLE
        # SharePoint site role
        Add-SiSAccessPackageResource -AccessPackageId $apId -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -RoleName "Members"

    .EXAMPLE
        # Swap a resource (naming standard: the package stays, the content changes)
        Add-SiSAccessPackageResource    -AccessPackageId $apId -GroupId $licE7GroupId
        Remove-SiSAccessPackageResource -AccessPackageId $apId -GroupId $licE5GroupId

    .OUTPUTS
        SiSGovernance.ResourceChangeResult, one per package: AccessPackageId, AccessPackageName, ResourceType,
        Resource, Role, Status (Added / AlreadyAdded / Preview - ... / Cancelled / Failed), Error.

    .NOTES
        Required scopes: EntitlementManagement.ReadWrite.All
        Least privileged role: Access package manager on the catalog (via PIM).
        Adding a resource to a catalog may also require rights on the resource
        itself (e.g. group owner or app owner), depending on the catalog setup.
    #>

    [OutputType('SiSGovernance.ResourceChangeResult')]
    # The confirmation is asked once for the whole run, in Invoke-AccessPackageResourceChange -
    # -WhatIf and -Confirm reach it through the preference variables
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is called in Invoke-AccessPackageResourceChange, which this function calls')]
    [CmdletBinding(DefaultParameterSetName = 'Group', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Id')]
        [guid[]]$AccessPackageId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [guid]$GroupId,

        [Parameter(Mandatory = $false, ParameterSetName = 'Group')]
        [ValidateSet('Member', 'Owner')]
        [string]$Role = 'Member',

        [Parameter(Mandatory = $true, ParameterSetName = 'Application')]
        [guid]$ApplicationId,

        [Parameter(Mandatory = $true, ParameterSetName = 'SharePoint')]
        [ValidatePattern('^https://')]
        [string]$SiteUrl,

        [Parameter(Mandatory = $true, ParameterSetName = 'Application')]
        [Parameter(Mandatory = $true, ParameterSetName = 'SharePoint')]
        [string]$RoleName
    )

    begin {
        $collectedIds = [System.Collections.Generic.List[string]]::new()
    }

    process {
        # Pipeline input (e.g. from New-SiSAccessPackage) is collected first, so
        # there's one preview and one confirmation for all packages
        foreach ($id in $AccessPackageId) { $collectedIds.Add($id.ToString('D')) }
    }

    end {
        $ids = @($collectedIds | Sort-Object -Unique)
        if ($ids.Count -eq 0) {
            Write-Warning "No access packages received. Nothing to do."
            return
        }
        $spec = ConvertTo-AccessPackageResourceSpec -Type $PSCmdlet.ParameterSetName `
            -GroupId $(if ($GroupId) { $GroupId.ToString('D') }) -GroupRole $Role -ApplicationId $(if ($ApplicationId) { $ApplicationId.ToString('D') }) -SiteUrl $SiteUrl -RoleName $RoleName

        Invoke-AccessPackageResourceChange -Action Add -AccessPackageId $ids -Spec $spec
    }
}
