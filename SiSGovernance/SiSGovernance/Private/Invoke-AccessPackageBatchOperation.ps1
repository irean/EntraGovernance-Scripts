function Invoke-AccessPackageBatchOperation {
    <#
    .SYNOPSIS
        Submits adminAdd/adminRemove requests for a list of already-resolved
        users, in batches of up to $BatchSize. adminAdd has no pre-check - every
        user is submitted and the resulting status is read entirely from Graph's
        own response. adminRemove first resolves each user's existing assignment
        id via Resolve-AccessPackageAssignmentIds, since Graph's adminRemove needs
        that id and has no other way to identify the assignment to remove; users
        with nothing to remove are reported as NotAssigned without ever being
        submitted.
    .OUTPUTS
        Array of PSCustomObject: UserPrincipalName, DisplayName, ObjectId,
        Status (Submitted / AlreadyAssigned / NotAssigned / OpenRequestExists / Failed), Error.
    .NOTES
        Status meanings for the non-Submitted cases
        Graph responses:
          AlreadyAssigned    - adminAdd, target already has the assignment (409 InvalidRequestExistingGrant)
          NotAssigned        - adminRemove, target has no active assignment to remove (404 InvalidRequestNoActiveGrant)
          OpenRequestExists  - a request (add or remove) for this target/access package is already pending (400 InvalidRequest / details ExistingOpenRequest)
    #>

    # One list on purpose (the caller gets it in one piece, also with 1 item)
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentPolicyId,

        [Parameter(Mandatory = $true)]
        [array]$UserList,

        [Parameter(Mandatory = $true)]
        [ValidateSet("adminAdd", "adminRemove")]
        [string]$RequestType,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$DelayMs = 1000
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $toSubmit = [System.Collections.Generic.List[object]]::new()

    if ($RequestType -eq 'adminRemove') {
        # adminRemove identifies the assignment to remove purely by its own
        # id (assignment.id) - Graph has no other way to reference it, so
        # this lookup is required, not an optional pre-check.
        Write-Host "`n Looking up existing assignments to resolve removal targets..." -ForegroundColor Cyan
        $lookupResult = Resolve-AccessPackageAssignmentIds -AccessPackageId $AccessPackageId -UserList $UserList
        if (-not $lookupResult) {
            # Without the lookup nobody can be removed - and nobody should be
            # reported as NotAssigned either, since that isn't known
            foreach ($user in $UserList) {
                $results.Add([PSCustomObject]@{
                        UserPrincipalName = $user.userPrincipalName
                        DisplayName       = $user.displayName
                        ObjectId          = $user.id
                        Status            = 'Failed'
                        Error             = 'Could not look up existing assignments'
                    })
            }
            return ,@($results)
        }

        foreach ($user in $lookupResult.NotFound) {
            Write-Host "  Not assigned (nothing to remove): $($user.userPrincipalName)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]@{
                    UserPrincipalName = $user.userPrincipalName
                    DisplayName       = $user.displayName
                    ObjectId          = $user.id
                    Status            = 'NotAssigned'
                    Error             = $null
                })
        }

        foreach ($entry in $lookupResult.Resolved) {
            $body = @{
                requestType = 'adminRemove'
                assignment  = @{ id = $entry.AssignmentId }
            }
            $toSubmit.Add(@{
                    CorrelationKey = $entry.User
                    Method         = 'POST'
                    Url            = '/identityGovernance/entitlementManagement/assignmentRequests'
                    Body           = $body
                })
        }
    }
    else {

        foreach ($user in $UserList) {
            $body = @{
                requestType = $RequestType
                assignment  = @{
                    accessPackageId    = $AccessPackageId
                    assignmentPolicyId = $AssignmentPolicyId
                    target              = @{ objectId = $user.id }
                }
            }

            $toSubmit.Add(@{
                    CorrelationKey = $user
                    Method         = 'POST'
                    Url            = '/identityGovernance/entitlementManagement/assignmentRequests'
                    Body           = $body
                })
        }
    }

    Write-Host "`n Submitting $RequestType for $($toSubmit.Count) user(s) via batch..." -ForegroundColor Cyan

    if ($toSubmit.Count -gt 0) {
        $responses = Invoke-GraphBatch -Requests @($toSubmit) -BatchSize $BatchSize -DelayMs $DelayMs

        foreach ($r in $responses) {
            $user = $r.CorrelationKey
            if ($r.Status -in 200, 201, 202) {
                Write-Host "  $RequestType submitted: $($user.userPrincipalName)" -ForegroundColor Green
                $results.Add([PSCustomObject]@{
                        UserPrincipalName = $user.userPrincipalName
                        DisplayName       = $user.displayName
                        ObjectId          = $user.id
                        Status            = 'Submitted'
                        Error             = $null
                    })
            }
            else {
                $errorCode    = $r.Body.error.code
                $errorMessage = $r.Body.error.message
                $detailCodes  = @($r.Body.error.details | ForEach-Object { $_.code })

                if ($errorCode -eq 'InvalidRequestExistingGrant') {
                    Write-Host "  Already assigned (caught at submit time): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'AlreadyAssigned'
                }
                elseif ($errorCode -eq 'InvalidRequestNoActiveGrant') {
                    Write-Host "  Not assigned (nothing to remove): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'NotAssigned'
                }
                elseif ($detailCodes -contains 'ExistingOpenRequest') {
                    Write-Host "  Open request already pending: $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'OpenRequestExists'
                }
                elseif ($errorMessage -match 'already') {
                    # Fallback for a wording/code variant we haven't seen confirmed yet.
                    Write-Host "  Already assigned (caught at submit time): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'AlreadyAssigned'
                }
                else {
                    Write-Host "  Failed: $($user.userPrincipalName) - $errorMessage" -ForegroundColor Red
                    $status = 'Failed'
                }
                $results.Add([PSCustomObject]@{
                        UserPrincipalName = $user.userPrincipalName
                        DisplayName       = $user.displayName
                        ObjectId          = $user.id
                        Status            = $status
                        Error             = $errorMessage
                    })
            }
        }
    }

    return ,@($results)
}
