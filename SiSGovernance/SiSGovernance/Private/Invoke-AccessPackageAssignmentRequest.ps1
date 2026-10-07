function Invoke-AccessPackageAssignmentRequest {
    <#
    .SYNOPSIS
        Engine behind Add-SiSAccessPackageAssignment and
        Remove-SiSAccessPackageAssignment: resolves the target users, previews,
        confirms once and submits adminAdd/adminRemove requests in batches.
    .NOTES
        Internal helper - call Add-SiSAccessPackageAssignment or
        Remove-SiSAccessPackageAssignment instead. Exactly one of -AdminAdd /
        -AdminRemove must be given.
    #>

    [OutputType('SiSGovernance.AssignmentResult')]
    [CmdletBinding(DefaultParameterSetName = 'Users', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentPolicyId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Excel')]
        [string]$ExcelPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Filter')]
        [string]$Filter,

        [Parameter(Mandatory = $true, ParameterSetName = 'Users', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$UserPrincipalName,

        [Parameter(Mandatory = $false)]
        [switch]$AdminAdd,

        [Parameter(Mandatory = $false)]
        [switch]$AdminRemove,

        [Parameter(Mandatory = $false)]
        [int]$MaxUsers = 500,

        [Parameter(Mandatory = $false)]
        [switch]$SkipReport,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$DelayMs = 1000
    )

    begin {
        # Checked once, before anything is collected from the pipeline
        $abort = $false
        if ($AdminAdd.IsPresent -eq $AdminRemove.IsPresent) {
            Write-Error -Message "Specify exactly one of -AdminAdd or -AdminRemove." -Category InvalidArgument
            $abort = $true
        }
        $collectedUpns = [System.Collections.Generic.List[string]]::new()
    }

    process {
        # Pipeline input arrives one item at a time - collect everything first,
        # so the preview, -MaxUsers, the confirmation and the batching happen once
        if ($abort -or $PSCmdlet.ParameterSetName -ne 'Users') { return }
        foreach ($upn in $UserPrincipalName) {
            if ("$upn".Trim()) { $collectedUpns.Add("$upn".Trim()) }
        }
    }

    end {
        if ($abort) { return }
        if ($PSCmdlet.ParameterSetName -eq 'Users') {
            # Same user piped in twice (e.g. member of two lists) -> one request
            $UserPrincipalName = @($collectedUpns | Sort-Object -Unique)
            if ($UserPrincipalName.Count -eq 0) {
                Write-Warning "No users received. Nothing to do."
                return
            }
        }

        $requestType = if ($AdminAdd) { 'adminAdd' } else { 'adminRemove' }
        $operation = if ($AdminAdd) { 'ADD' } else { 'REMOVE' }

        Write-Host "==========================================" -ForegroundColor DarkGray
        Write-Host "   ACCESS PACKAGE ASSIGNMENT ($operation)   " -ForegroundColor Cyan
        Write-Host "==========================================" -ForegroundColor DarkGray

        # --- OUTPUT FOLDER (first, so the run never stops halfway to ask) ---
        $folderPath = $null
        if (-not $SkipReport) {
            $folderPath = Resolve-OutputFolder -OutputPath $OutputPath
            if (-not $folderPath) { return }
        }

        if (-not (Confirm-GraphConnection)) { return }

        $context = Resolve-AccessPackageContext -AccessPackageId $AccessPackageId -AssignmentPolicyId $AssignmentPolicyId
        if (-not $context) { return }

        $resolution = Resolve-AccessPackageTargetUsers -Source $PSCmdlet.ParameterSetName `
            -ExcelPath $ExcelPath -Filter $Filter -UserPrincipalName $UserPrincipalName
        if (-not $resolution -or $resolution.TargetUsers.Count -eq 0) {
            Write-Warning "No users to process. Nothing to do."
            return
        }
        $targetUsers = $resolution.TargetUsers

        if ($targetUsers.Count -gt $MaxUsers) {
            Write-Error -Message "This run would touch $($targetUsers.Count) users, which exceeds -MaxUsers ($MaxUsers). Narrow the input, or re-run with a higher -MaxUsers if this is intentional." -Category LimitsExceeded
            return
        }

        Write-Host "`n Preview of target users (first 10 of $($targetUsers.Count)):" -ForegroundColor Cyan
        $targetUsers | Select-Object -First 10 -Property displayName, userPrincipalName | Format-Table -AutoSize | Out-Host

        Write-Host "`n $operation $($targetUsers.Count) user(s):" -ForegroundColor Yellow
        Write-Host "   Package        : $($context.AccessPackageName)" -ForegroundColor White
        Write-Host "   Policy         : $($context.AssignmentPolicyName)" -ForegroundColor White

        # One confirmation for the whole run, also when many users are piped in
        $action = if ($AdminAdd) { 'Add assignment' } else { 'Remove assignment' }
        $target = "$($targetUsers.Count) user(s) on access package '$($context.AccessPackageName)'"
        if (-not $PSCmdlet.ShouldProcess($target, $action)) {
            if ($WhatIfPreference) {
                $previewStatus = if ($AdminAdd) { 'Preview - Add' } else { 'Preview - Remove' }
                foreach ($u in $targetUsers) {
                    [PSCustomObject]@{
                        PSTypeName        = 'SiSGovernance.AssignmentResult'
                        UserPrincipalName = $u.userPrincipalName
                        DisplayName       = $u.displayName
                        ObjectId          = $u.id
                        Status            = $previewStatus
                        Error             = $null
                    }
                }
            }
            Write-Warning "Cancelled - no changes were made."
            return
        }

        $results = Invoke-AccessPackageBatchOperation `
            -AccessPackageId $AccessPackageId `
            -AssignmentPolicyId $AssignmentPolicyId `
            -UserList $targetUsers `
            -RequestType $requestType `
            -BatchSize $BatchSize `
            -DelayMs $DelayMs

        foreach ($f in $resolution.NotFound) {
            $results += [PSCustomObject]@{
                UserPrincipalName = $f.userPrincipalName
                DisplayName       = $null
                ObjectId          = $null
                Status            = 'Failed - User not found'
                Error             = $f.Error
            }
        }

        Write-Host "`n Results:" -ForegroundColor Cyan

        $results | Format-Table | Out-String -Width 4096 | Write-Host

        if ($SkipReport) {
            Write-Host " -SkipReport specified: results not exported." -ForegroundColor Yellow
        }
        elseif (@($results).Count -gt 0) {
            # Timestamp to the second, so a second run the same day never overwrites the first report
            $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
            $safeName = $context.AccessPackageName -replace '[^\w\-]', '_'
            $exportPath = Join-Path $folderPath "$operation-$safeName-$stamp.xlsx"

            $excel = Export-SafeExcelTable -InputObject @($results) -Path $exportPath -WorksheetName 'Results' -TableName 'Results'
            Close-ExcelPackage $excel

            Write-Host " Results exported to: $exportPath" -ForegroundColor Green
        }

        $summary = $results | Group-Object Status | Sort-Object Count -Descending
        Write-Host "`n==========================================" -ForegroundColor DarkGray
        Write-Host "   OPERATION COMPLETE" -ForegroundColor Cyan
        Write-Host "==========================================" -ForegroundColor DarkGray
        foreach ($s in $summary) {

            $statusLabel = if ($s.Name -eq 'Submitted') { 'Success' } else { $s.Name }
            Write-Host "   ${statusLabel}: $($s.Count)" -ForegroundColor White
            if ($s.Name -like 'Failed*') {

                $errorGroups = $s.Group | Group-Object Error | Sort-Object Count -Descending
                foreach ($eg in $errorGroups) {
                    $errorLabel = if ($eg.Name) { $eg.Name } else { '(no error message)' }
                    Write-Host "      - $($errorLabel): $($eg.Count)" -ForegroundColor DarkYellow
                }
            }
        }

        # One object per user, so the results can be piped on (Where-Object, Export-Excel...)
        foreach ($r in $results) {
            $r.PSObject.TypeNames.Insert(0, 'SiSGovernance.AssignmentResult')
            $r
        }
    }
}
