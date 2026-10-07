function Resolve-UsersByUpn {
    <#
    .SYNOPSIS
        Batch-resolves a list of UPNs to id/displayName/userPrincipalName via
        Microsoft Graph $batch, instead of one GET per user.
    .OUTPUTS
        PSCustomObject with .Resolved (array of user objects) and .NotFound
        (array of @{userPrincipalName; Error} for UPNs that didn't resolve).
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$UserPrincipalName
    )

    $requests = $UserPrincipalName | ForEach-Object {
        @{
            CorrelationKey = $_
            Method         = 'GET'
            Url            = "/users/$($_)?`$select=id,displayName,userPrincipalName"
        }
    }

    $responses = Invoke-GraphBatch -Requests $requests

    $resolved = [System.Collections.Generic.List[object]]::new()
    $notFound = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $responses) {
        if ($r.Status -eq 200) {
            $resolved.Add([PSCustomObject]@{
                    id                = $r.Body.id
                    displayName       = $r.Body.displayName
                    userPrincipalName = $r.Body.userPrincipalName
                })
        }
        else {
            $notFound.Add([PSCustomObject]@{
                    userPrincipalName = $r.CorrelationKey
                    Error             = $r.Body.error.message
                })
        }
    }

    return [PSCustomObject]@{
        Resolved = @($resolved)
        NotFound = @($notFound)
    }
}
