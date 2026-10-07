function Get-SiSGraphUser {
    <#
    .SYNOPSIS
        Retrieves users from Microsoft Graph matching an OData $filter expression.
    .PARAMETER Filter
        An OData filter expression, e.g. "department eq 'Sales'".
    .PARAMETER Select
        Fields to return. Defaults to what the rest of the module expects.
    .PARAMETER NoAdvancedQuery
        Skips ConsistencyLevel: eventual. By default it's always sent, since
        advanced filter operators (and $count) require it.
    .EXAMPLE
        Get-SiSGraphUser -Filter "userType eq 'Member' and employeeType eq 'employee'"
    .EXAMPLE
        # Straight into an access package
        Get-SiSGraphUser -Filter "department eq 'Sales'" |
            Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId
    .OUTPUTS
        One user object per user: id, displayName, userPrincipalName (or what -Select asks for).
    .NOTES
        Required scopes: User.Read.All. Uses the existing Microsoft Graph
        connection (Connect-MgGraph) - the module never signs in by itself.
    #>

    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$Select = 'id,displayName,userPrincipalName',

        [Parameter(Mandatory = $false)]
        [switch]$NoAdvancedQuery
    )

    if (-not (Confirm-GraphConnection -Scopes 'User.Read.All')) { return }

    # Encoded, so a filter with & or # (or anything else) can't break the URL
    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$([uri]::EscapeDataString($Filter))&`$select=$([uri]::EscapeDataString($Select))&`$count=true"

    Write-Host "`n Querying Graph for users matching filter:" -ForegroundColor Cyan
    Write-Host "   $Filter" -ForegroundColor White

    try {
        $users = @(Get-GraphPagedResult -Uri $uri -Eventual:(-not $NoAdvancedQuery))
    }
    catch {
        Write-Error -Message "Graph query failed - check the filter syntax. $($_.Exception.Message)" -Category InvalidArgument -TargetObject $Filter
        return
    }

    if (-not $users -or $users.Count -eq 0) {
        Write-Warning "No users matched the filter."
        return
    }

    Write-Host "Found $($users.Count) matching user(s)." -ForegroundColor Green
    # One user at a time down the pipeline, so it can be piped straight on
    foreach ($user in $users) { $user }
}
