using namespace System.Net

param($Request, $TriggerMetadata)

# -----------------------------------------------------------------------------
# DistributionListMembership function
#
# Security model (no secrets/keys anywhere in this function):
#   - Inbound auth: authLevel is "anonymous" in function.json on purpose.
#     Access is instead enforced at the Azure AD layer: the Function App's
#     Enterprise Application (App Registration) must have
#     "appRoleAssignmentRequired" = true, and only the Logic Apps' shared
#     User-Assigned Managed Identity. 
#   - Outbound auth to Exchange Online: Using the same User-Assigned Managed Identity
#     to keep everything grouped together under one identity
#
#
# Expected request body:
# {
#   "UserId": "<AAD ObjectId or UPN of the target user>",
#   "Action": "Add" | "Remove",
#   "DistributionLists": ["dl-a@contoso.com", "dl-b@contoso.com"],
#   "AccessPackageAssignmentRequestId": "<guid, for correlation in logs>"
# }
#
# Response body:
# {
#   "OverallStatus": "Success" | "PartialFailure" | "Failed",
#   "Results": [ { "DistributionList": "...", "Status": "Success|Failed", "Note"?, "Error"? } ]
# }
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

$body = $Request.Body
$userId = $body.UserId
$action = $body.Action
$distributionLists = $body.DistributionLists
$requestId = $body.AccessPackageAssignmentRequestId

Write-Output "[$requestId] Processing '$action' for user '$userId' against $($distributionLists.Count) distribution list(s)."

if (-not $userId -or -not $action -or -not $distributionLists -or $distributionLists.Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @{
                OverallStatus = "Failed"
                Results       = @()
                Error         = "Missing UserId, Action or DistributionLists in request body." 
            }
        })
    return
}

$organization = $env:ExchangeOnlineOrganization
if (-not $organization) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = @{
                OverallStatus = "Failed"
                Results       = @()
                Error         = "App setting 'ExchangeOnlineOrganization' is not configured on this Function App." 
            }
        })
    return
}

$UamiClientId = $env:UamiClientId
if (-not $UamiClientId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = @{
                OverallStatus = "Failed"
                Results       = @()
                Error         = "App setting 'UamiClientId' is not configured on this Function App." 
            }
        })
    return
}

$results = @()


try {
    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    Connect-ExchangeOnline -ManagedIdentity -ManagedIdentityAccountId $UamiClientId `
        -Organization $organization -ShowBanner:$false -ErrorAction Stop

    Write-Output "[$requestId] Connected to Exchange Online."

    foreach ($dl in $distributionLists) {
        try {
            switch ($action) {
                "Add" {
                    Add-DistributionGroupMember -Identity $dl -Member $userId -ErrorAction Stop
                    $results += [PSCustomObject]@{ DistributionList = $dl; Status = "Success" }
                }
                "Remove" {
                    Remove-DistributionGroupMember -Identity $dl -Member $userId -Confirm:$false -ErrorAction Stop
                    $results += [PSCustomObject]@{ DistributionList = $dl; Status = "Success" }
                }
                default {
                    throw "Unsupported Action '$action'. Expected 'Add' or 'Remove'."
                }
            }
        }
        catch {
            $errMsg = $_.Exception.Message

            # Treat "already there" / "already gone" as idempotent success rather than
            # a failure, so repeated or out-of-order Add/Remove calls don't create noise.
            if ($errMsg -match "already a member") {
                $results += [PSCustomObject]@{
                    DistributionList = $dl
                    Status           = "Success"
                    Note             = "User was already a member" 
                }
            }
            elseif ($errMsg -match "couldn't be found|isn't a member|doesn't exist") {
                $results += [PSCustomObject]@{
                    DistributionList = $dl
                    Status           = "Success"
                    Note             = "User was already not a member" 
                }
            }
            else {
                Write-Error "[$requestId] Failed '$action' on '$dl' for '$userId': $errMsg"
                $results += [PSCustomObject]@{
                    DistributionList = $dl
                    Status           = "Failed"
                    Error            = $errMsg 
                }
            }
        }
    }
}
catch {
    Write-Error "[$requestId] Fatal error connecting to Exchange Online: $($_.Exception.Message)"
    $results = $distributionLists | ForEach-Object {
        [PSCustomObject]@{
            DistributionList = $_
            Status           = "Failed"
            Error            = "Exchange Online connection failed: $($_.Exception.Message)" 
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

$hasFailed = ($results | Where-Object { $_.Status -eq "Failed" }).Count -gt 0
$hasSucceded = ($results | Where-Object { $_.Status -eq "Success" }).Count -gt 0

$overallStatus =
if ($hasFailed -and $hasSucceded) { "PartialFailure" }
elseif ($hasFailed) { "Failed" }
else { "Success" }

# Structured log line -> Application Insights, correlated on AccessPackageAssignmentRequestId
# so this can be queried/alerted on independently of whatever Entra does with the run status.
Write-Output (@{
        RequestId     = $requestId
        UserId        = $userId
        Action        = $action
        OverallStatus = $overallStatus
        Results       = $results
    } | ConvertTo-Json -Depth 5 -Compress)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ "Content-Type" = "application/json" }
        Body       = @{
            OverallStatus = $overallStatus
            Results       = $results
        }
    })
