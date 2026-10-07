function ConvertTo-AccessPackageResourceSpec {
    <#
    .SYNOPSIS
        Turns the per-type parameters (Group / Application / SharePoint) into the
        one shape Entitlement Management uses for every resource type:
        originSystem + originId + which role.
    .NOTES
        Internal helper, used by the *-AccessPackageResource functions. A new
        resource type = one more case here, nothing else changes.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Group', 'Application', 'SharePoint')]
        [string]$Type,

        [string]$GroupId,
        [string]$GroupRole = 'Member',
        [string]$ApplicationId,
        [string]$SiteUrl,
        [string]$RoleName
    )

    switch ($Type) {
        'Group' {
            [PSCustomObject]@{
                Type         = 'Group'
                OriginSystem = 'AadGroup'
                OriginId     = $GroupId
                RoleName     = $GroupRole
                # Group roles are always Member_<groupId> / Owner_<groupId>
                RoleOriginId = "$($GroupRole)_$GroupId"
            }
        }
        'Application' {
            [PSCustomObject]@{
                Type         = 'Application'
                OriginSystem = 'AadApplication'
                OriginId     = $ApplicationId
                RoleName     = $RoleName
                RoleOriginId = $null
            }
        }
        'SharePoint' {
            [PSCustomObject]@{
                Type         = 'SharePoint'
                OriginSystem = 'SharePointOnline'
                OriginId     = $SiteUrl.TrimEnd('/')
                RoleName     = $RoleName
                RoleOriginId = $null
            }
        }
    }
}
