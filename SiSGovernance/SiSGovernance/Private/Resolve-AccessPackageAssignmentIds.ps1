function Resolve-AccessPackageAssignmentIds {
    <#
    .SYNOPSIS
        Resolves each user in $UserList to their existing accessPackageAssignment
        id for the given access package, by fetching all current assignments once
        (paginated, expanding target) instead of one GET per user.
    .NOTES
        Needed only for adminRemove. Unlike adminAdd, which identifies the target
        via target.objectId/accessPackageId/assignmentPolicyId, Graph's adminRemove
        identifies the assignment to remove purely by the assignment's own id -
        there is no other way to reference it, so this lookup isn't an optional
        pre-check the way an add-side duplicate check would be.
    .OUTPUTS
        PSCustomObject with Resolved (array of {User; AssignmentId}) and
        NotFound (users with no existing assignment - nothing to remove).
        Writes an error and returns $null if the lookup itself fails.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [array]$UserList
    )

    # state eq 'Delivered' matters here: without it, Graph's list includes
    # expired assignments alongside current ones, and an expired assignment's
    # id is not something adminRemove should be pointed at.
    $uri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=accessPackage/id eq '$AccessPackageId' and state eq 'Delivered'&`$expand=target&`$select=id,target&`$count=true"

    try {
        $assignments = @(Get-GraphPagedResult -Uri $uri -Eventual)
    }
    catch {
        Write-Error -Message "Could not look up the existing assignments to remove. $($_.Exception.Message)" -Category ReadError -TargetObject $AccessPackageId
        return $null
    }

    # Build a lookup of target user id -> assignment id from every current
    # assignment on this access package, one query instead of one per user.
    $lookup = @{}
    foreach ($a in $assignments) {
        $targetId = $null
        if ($a.target) {
            if ($a.target.id) { $targetId = $a.target.id }
            elseif ($a.target.objectId) { $targetId = $a.target.objectId }
        }
        if ($targetId) { $lookup[$targetId] = $a.id }
    }

    $resolved = [System.Collections.Generic.List[object]]::new()
    $notFound = [System.Collections.Generic.List[object]]::new()
    foreach ($user in $UserList) {
        if ($lookup.ContainsKey($user.id)) {
            $resolved.Add([PSCustomObject]@{ User = $user; AssignmentId = $lookup[$user.id] })
        }
        else {
            $notFound.Add($user)
        }
    }

    return [PSCustomObject]@{ Resolved = @($resolved); NotFound = @($notFound) }
}
