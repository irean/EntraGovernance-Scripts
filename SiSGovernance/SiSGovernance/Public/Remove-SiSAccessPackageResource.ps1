function Remove-SiSAccessPackageResource {
    <#
    .SYNOPSIS
        Removes a resource role (group, application or SharePoint site) from one
        or more access packages. The resource stays in the catalog.

    .DESCRIPTION
        The counterpart of Add-SiSAccessPackageResource, and together they're how a
        resource is swapped without touching the package, its name or its
        approvals (see the naming standard).

        Reads every package first, shows one preview and asks for confirmation once.
        Packages that don't have the role are reported as NotOnPackage.
        Everyone assigned to the package loses the role.

    .PARAMETER AccessPackageId
        One or more access package ObjectIds. Accepts pipeline input by property name (Id / AccessPackageId).

    .PARAMETER GroupId
        Entra group ObjectId. (ParameterSet 'Group', default)

    .PARAMETER Role
        Group role: Member (default) or Owner. (ParameterSet 'Group')

    .PARAMETER ApplicationId
        ObjectId of the application's service principal. (ParameterSet 'Application')

    .PARAMETER SiteUrl
        SharePoint Online site URL. (ParameterSet 'SharePoint')

    .PARAMETER RoleName
        For applications and SharePoint: the role's display name or originId.

    .PARAMETER WhatIf
        Reads and shows what would change, then stops. Returns 'Preview - <action>'
        per package.

    .PARAMETER Confirm
        Asks before changing (the default). -Confirm:$false changes without asking.

    .EXAMPLE
        Remove-SiSAccessPackageResource -AccessPackageId $apId -GroupId $licE5GroupId

    .OUTPUTS
        SiSGovernance.ResourceChangeResult, one per package: AccessPackageId, AccessPackageName, ResourceType,
        Resource, Role, Status (Removed / NotOnPackage / Preview - ... / Cancelled / Failed), Error.

    .NOTES
        Required scopes: EntitlementManagement.ReadWrite.All
        Least privileged role: Access package manager on the catalog (via PIM)
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

        Invoke-AccessPackageResourceChange -Action Remove -AccessPackageId $ids -Spec $spec
    }
}
