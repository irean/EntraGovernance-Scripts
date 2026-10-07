function Export-SiSDistributionList {
    <#
    .SYNOPSIS
        Exports all distribution lists in Entra ID to Excel, as the starting
        point for reviewing names/descriptions with HR before creating access
        packages from the file.

    .DESCRIPTION
        Read only - nothing is changed in Entra.

        Gets every distribution list (mail-enabled, not security-enabled, not a
        Microsoft 365 group) and, via Graph $batch, its member count and owners.
        Mail-enabled security groups and dynamic distribution lists are not
        included (dynamic ones don't exist in Entra/Graph at all).

        Columns written:
          From Entra : ObjectId, DisplayName, PrimarySmtpAddress,
                       OnPremisesSyncEnabled, MemberCount, Owners
          Fill in    : Include (Yes/No dropdown), AccessPackageDisplayName,
                       AccessPackageDescription, ScopingNotes
          Written by Sync-SiSAccessPackage :
                       AccessPackageId, Status, StatusMessage

    .PARAMETER OutputPath
        Folder for the Excel file. Without it, a folder dialog opens at the
        start of the run.

    .PARAMETER BatchSize
        Requests per Graph $batch call. Default and max 20.

    .EXAMPLE
        Export-SiSDistributionList

    .EXAMPLE
        # No folder dialog
        Export-SiSDistributionList -OutputPath "C:\Reports\DistributionLists"

    .OUTPUTS
        SiSGovernance.DistributionListRow, one per distribution list - the same
        rows and columns as in the Excel file.

    .NOTES
        Required scopes: GroupMember.Read.All (read only - no Entitlement Management scope)
        Owners in Graph don't always match ManagedBy in Exchange for
        distribution lists - verify against Exchange before relying on it.
    #>

    [OutputType('SiSGovernance.DistributionListRow')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20
    )

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   EXPORT DISTRIBUTION LISTS   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    # --- OUTPUT FOLDER (first, so the run never stops halfway to ask) -------
    $folderPath = Resolve-OutputFolder -OutputPath $OutputPath
    if (-not $folderPath) { return }

    # Read only: no Entitlement Management scope at all. GroupMember.Read.All
    # covers listing groups, members and owners - narrower than Group.Read.All,
    # which also reads M365 group content (conversations, calendar...).
    if (-not (Confirm-GraphConnection -Scopes 'GroupMember.Read.All')) { return }

    Write-Host "`n--- DISTRIBUTION LISTS ---" -ForegroundColor Cyan
    # Distribution lists only: mail-enabled, not security-enabled, not M365 groups.
    # NOT groupTypes/any(...) is an advanced query -> needs eventual + $count.
    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=mailEnabled eq true and securityEnabled eq false and NOT groupTypes/any(c:c eq 'Unified')&`$select=id,displayName,mail,onPremisesSyncEnabled&`$count=true"

    try {
        $groups = @(Get-GraphPagedResult -Uri $uri -Eventual)
    }
    catch {
        Write-Error -Message "Failed to read distribution lists. $($_.Exception.Message)" -Category ReadError
        return
    }

    if ($groups.Count -eq 0) {
        Write-Warning "No distribution lists found."
        return
    }
    Write-Host "Found $($groups.Count) distribution list(s)." -ForegroundColor Green

    $syncedCount = @($groups | Where-Object { $_.onPremisesSyncEnabled -eq $true }).Count
    if ($syncedCount -gt 0) {
        Write-Host "   $syncedCount of them are synced from on-premises - Exchange Online can't manage their membership." -ForegroundColor Yellow
    }

    Write-Host "`n--- MEMBER COUNT AND OWNERS ---" -ForegroundColor Cyan
    $requests = foreach ($g in $groups) {
        @{
            CorrelationKey = @{ Id = $g.id; Kind = 'Count' }
            Method         = 'GET'
            Url            = "/groups/$($g.id)/members?`$count=true&`$top=1&`$select=id"
            Headers        = @{ ConsistencyLevel = 'eventual' }
        }
        @{
            CorrelationKey = @{ Id = $g.id; Kind = 'Owners' }
            Method         = 'GET'
            Url            = "/groups/$($g.id)/owners?`$select=displayName,userPrincipalName,mail"
        }
    }

    $responses = Invoke-GraphBatch -Requests @($requests) -BatchSize $BatchSize

    $memberCount = @{}
    $owners = @{}
    foreach ($r in $responses) {
        $id = $r.CorrelationKey.Id
        if ($r.Status -ne 200) {
            if ($r.CorrelationKey.Kind -eq 'Count') { $memberCount[$id] = 'Error' }
            else { $owners[$id] = 'Error' }
            continue
        }
        if ($r.CorrelationKey.Kind -eq 'Count') {
            $memberCount[$id] = $r.Body['@odata.count']
        }
        else {
            $owners[$id] = (@($r.Body.value) | Where-Object { $_ } | ForEach-Object {
                    if ($_.userPrincipalName) { $_.userPrincipalName }
                    elseif ($_.mail) { $_.mail }
                    else { $_.displayName }
                }) -join '; '
        }
    }

    $rows = foreach ($g in ($groups | Sort-Object displayName)) {
        $row = [ordered]@{}
        foreach ($c in (Get-DistributionListColumns)) { $row[$c] = $null }
        $row.ObjectId              = $g.id
        $row.DisplayName           = $g.displayName
        $row.PrimarySmtpAddress    = $g.mail
        $row.OnPremisesSyncEnabled = [bool]$g.onPremisesSyncEnabled
        $row.MemberCount           = $memberCount[$g.id]
        $row.Owners                = $owners[$g.id]
        [PSCustomObject]$row
    }

    Write-Host "`n Preview (first 10 of $(@($rows).Count)):" -ForegroundColor Cyan
    $rows | Select-Object -First 10 -Property DisplayName, PrimarySmtpAddress, MemberCount, Owners | Format-Table -AutoSize | Out-Host

    $exportPath = Join-Path $folderPath "DistributionLists-$(Get-Date -Format 'yyyy-MM-dd_HHmmss').xlsx"
    Export-DistributionListWorkbook -Rows @($rows) -Path $exportPath

    Write-Host "`n==========================================" -ForegroundColor DarkGray
    Write-Host "   EXPORT COMPLETE" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   Exported $(@($rows).Count) distribution list(s) to: $exportPath" -ForegroundColor Green
    Write-Host "   Fill in Include, AccessPackageDisplayName, AccessPackageDescription" -ForegroundColor White
    Write-Host "   and ScopingNotes, then run Sync-SiSAccessPackage." -ForegroundColor White

    # The same rows as in the file, one object per distribution list
    foreach ($row in $rows) {
        $row.PSObject.TypeNames.Insert(0, 'SiSGovernance.DistributionListRow')
        $row
    }
}
