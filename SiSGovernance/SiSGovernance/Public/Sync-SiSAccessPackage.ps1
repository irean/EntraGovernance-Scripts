function Sync-SiSAccessPackage {
    <#
    .SYNOPSIS
        Creates, links or updates access packages (without policies) from the
        Excel file made by Export-SiSDistributionList, writes the
        AccessPackageId and a Status per row back to a new Excel file, and can
        output the distributionListMapping block for the Distribution List
        Membership Bicep.

    .DESCRIPTION
        Only rows with Include = Yes are processed. Rows with the same
        AccessPackageDisplayName become ONE access package - that's how several
        distribution lists end up behind the same package.

        The whole file is validated first, and every problem is reported at
        once. If any row is Invalid, nothing is created or changed, and the run
        ends with an error (after the results file is written).

        Per access package:
          AccessPackageId empty, no package with that name in the catalog -> Created
          AccessPackageId empty, one package with that name in the catalog -> Linked
              (id written back, description updated if it differs - no duplicate)
          AccessPackageId set, name/description differ from Entra         -> Updated
          AccessPackageId set, nothing differs                             -> Unchanged
          AccessPackageId set, package doesn't exist                       -> NotFound
          AccessPackageId set, package is in another catalog               -> CatalogMismatch
        Plus per row: Skipped (Include not Yes), Invalid, Failed, NotProcessed.

        Distribution list name, SMTP address and sync status are refreshed from
        Entra on every run, so the Bicep mapping always uses the current address.

        Results are written to a NEW file in the output folder (the input file
        is never overwritten). Use that file as input for the next run. The
        folder is chosen first - with -OutputPath, or in a dialog - so the run
        never stops halfway to ask for it.

        No assignment policies are created - add them separately.

    .PARAMETER ExcelPath
        Path to the Excel file (from Export-SiSDistributionList, or a
        previous run of this function).

    .PARAMETER CatalogId
        The ObjectId of the catalog. (ParameterSet 'CatalogId')

    .PARAMETER CatalogName
        Display name of the catalog. (ParameterSet 'CatalogName', default)
        Use the catalog the Distribution List Membership custom extension is
        registered on - otherwise the Logic App never reacts.

    .PARAMETER BicepOutput
        Also writes the distributionListMapping block (Bicep syntax, SMTP
        addresses) to the terminal and to a .bicepparam file next to the results.
        It replaces the whole block, so the Excel file must contain every
        distribution list that should be in the mapping.

    .PARAMETER OutputPath
        Folder for the results file (and the .bicepparam with -BicepOutput).
        Without it, a folder dialog opens at the start of the run.

    .PARAMETER WhatIf
        Validates and shows what would happen, writes 'Preview - <action>' per
        row to a Preview results file, and stops before changing anything.

    .PARAMETER Confirm
        Asks before creating or changing (the default). -Confirm:$false skips the
        question, so a run with -OutputPath needs no input at all.

    .PARAMETER MaxPackages
        Safety cap on how many access packages a run may create/change. Default 200.

    .PARAMETER BatchSize
        Requests per Graph $batch call. Default and max 20.

    .PARAMETER DelayMs
        Pause between batch calls for the create/update writes. Default 1000 ms.
        Reads are not delayed. Raised automatically if Graph reports it's close
        to the throttling limit.

    .EXAMPLE
        # Check the file first
        Sync-SiSAccessPackage -ExcelPath "C:\DistributionLists.xlsx" `
            -CatalogName "Distribution Lists" -WhatIf

    .EXAMPLE
        # Run it, and get the Bicep mapping
        Sync-SiSAccessPackage -ExcelPath "C:\DistributionLists.xlsx" `
            -CatalogName "Distribution Lists" -BicepOutput

    .EXAMPLE
        # No folder dialog
        Sync-SiSAccessPackage -ExcelPath "C:\DistributionLists.xlsx" `
            -CatalogName "Distribution Lists" -OutputPath "C:\Reports\AccessPackages"

    .EXAMPLE
        # Unattended: no dialog, no prompt
        Sync-SiSAccessPackage -ExcelPath "C:\DistributionLists.xlsx" `
            -CatalogName "Distribution Lists" -OutputPath "C:\Reports\AccessPackages" -Confirm:$false

    .OUTPUTS
        SiSGovernance.DistributionListRow, one per row - the same rows and columns
        as in the results file, with AccessPackageId, Status and StatusMessage.

    .NOTES
        Required scopes: EntitlementManagement.ReadWrite.All, GroupMember.Read.All
        Least privileged role: Access package manager on the catalog (via PIM)
    #>

    [OutputType('SiSGovernance.DistributionListRow')]
    [CmdletBinding(DefaultParameterSetName = 'CatalogName', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExcelPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'CatalogId')]
        [Nullable[guid]]$CatalogId,

        [Parameter(Mandatory = $true, ParameterSetName = 'CatalogName')]
        [string]$CatalogName,

        [Parameter(Mandatory = $false)]
        [switch]$BicepOutput,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [int]$MaxPackages = 200,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$DelayMs = 1000
    )

    $text = { param($v) if ($null -eq $v) { '' } else { "$v".Trim() } }
    $setRow = {
        param($row, [string]$status, [string]$message)
        $row.Status = $status
        if ($message) {
            $row.StatusMessage = if ($row.StatusMessage) { "$($row.StatusMessage); $message" } else { $message }
        }
    }

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   ACCESS PACKAGES FROM EXCEL   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    # -WhatIf: validate, show, write the preview file - change nothing
    $preview = [bool]$WhatIfPreference
    # A run that changes nothing because of bad input is still a failed run -
    # the error is written at the end, after the results file
    $runError = $null

    # --- OUTPUT FOLDER (first, so the run never stops halfway to ask) -------
    $folderPath = Resolve-OutputFolder -OutputPath $OutputPath
    if (-not $folderPath) { return }

    # --- IMPORT EXCEL (before connecting, so a bad file fails fast) ---------
    Write-Host "`n--- IMPORT EXCEL ---" -ForegroundColor Cyan
    if (-not (Test-Path $ExcelPath)) {
        Write-Error -Message "File not found: $ExcelPath" -Category ObjectNotFound -TargetObject $ExcelPath
        return
    }
    $raw = @(Import-Excel -Path $ExcelPath)
    if ($raw.Count -eq 0) {
        Write-Warning "No rows loaded from Excel."
        return
    }
    $fileColumns = @($raw[0].PSObject.Properties.Name)
    $required = @('ObjectId', 'Include', 'AccessPackageDisplayName', 'AccessPackageDescription', 'AccessPackageId')
    $missing = @($required | Where-Object { $fileColumns -notcontains $_ })
    if ($missing.Count -gt 0) {
        Write-Error -Message "The Excel file is missing column(s): $($missing -join ', '). Columns found: $($fileColumns -join ', ')" -Category InvalidData -TargetObject $ExcelPath
        return
    }

    $knownColumns = Get-DistributionListColumns
    # Normalize: known columns first in a fixed order, then any extra columns
    # as-is. Status/StatusMessage are reset - they describe THIS run only.
    $rows = for ($i = 0; $i -lt $raw.Count; $i++) {
        $src = $raw[$i]
        $row = [ordered]@{}
        foreach ($c in $knownColumns) {
            $row[$c] = if ($fileColumns -contains $c) { $src.$c } else { $null }
        }
        foreach ($c in $fileColumns) {
            if ($knownColumns -notcontains $c -and $c -ne '_ExcelRow') { $row[$c] = $src.$c }
        }
        $row.Status = $null
        $row.StatusMessage = $null
        $row._ExcelRow = $i + 2   # +1 header, +1 one-based
        [PSCustomObject]$row
    }
    $rows = @($rows)
    Write-Host "Loaded $($rows.Count) row(s) from Excel." -ForegroundColor Green

    if (-not (Confirm-GraphConnection -Scopes 'EntitlementManagement.ReadWrite.All', 'GroupMember.Read.All')) { return }

    $catalog = Resolve-AccessPackageCatalog -CatalogId $(if ($CatalogId) { $CatalogId.ToString('D') }) -CatalogName $CatalogName
    if (-not $catalog) { return }

    # --- VALIDATE ROWS -------------------------------------------------------
    Write-Host "`n--- VALIDATE ROWS ---" -ForegroundColor Cyan
    $included = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $include = & $text $row.Include
        if ($include -eq 'Yes') {
            $included.Add($row)
        }
        elseif ($include -eq 'No') {
            & $setRow $row 'Skipped' 'Include = No'
        }
        else {
            & $setRow $row 'Skipped' $(if ($include) { "Include is '$include', not Yes/No" } else { 'Include not set' })
        }
    }
    Write-Host "$($included.Count) row(s) marked Include = Yes." -ForegroundColor Green

    foreach ($row in $included) {
        $objectId = & $text $row.ObjectId
        if (-not $objectId) { & $setRow $row 'Invalid' 'ObjectId is empty' }
        elseif (-not (Test-IsGuid $objectId)) { & $setRow $row 'Invalid' "ObjectId '$objectId' is not a valid GUID" }
        $packageId = & $text $row.AccessPackageId
        if ($packageId -and -not (Test-IsGuid $packageId)) { & $setRow $row 'Invalid' "AccessPackageId '$packageId' is not a valid GUID" }
        if (-not (& $text $row.AccessPackageDisplayName)) { & $setRow $row 'Invalid' 'AccessPackageDisplayName is empty' }
        if (-not (& $text $row.AccessPackageDescription)) { & $setRow $row 'Invalid' 'AccessPackageDescription is empty' }
    }

    # Refresh every included distribution list from Entra, in batch - names and
    # addresses can have changed since the export, and the Bicep mapping must
    # use the current SMTP address.
    # Only valid GUIDs ever reach a Graph URL
    $objectIds = @($included | ForEach-Object { & $text $_.ObjectId } | Where-Object { $_ -and (Test-IsGuid $_) } | Sort-Object -Unique)
    $groupLookup = @{}
    if ($objectIds.Count -gt 0) {
        Write-Host "Checking $($objectIds.Count) distribution list(s) in Entra..." -ForegroundColor Green
        $requests = $objectIds | ForEach-Object {
            @{
                CorrelationKey = $_
                Method         = 'GET'
                Url            = "/groups/$($_)?`$select=id,displayName,mail,mailEnabled,securityEnabled,groupTypes,onPremisesSyncEnabled"
            }
        }
        foreach ($r in (Invoke-GraphBatch -Requests @($requests) -BatchSize $BatchSize)) {
            $groupLookup[$r.CorrelationKey] = $r
        }
    }

    foreach ($row in $included) {
        $id = & $text $row.ObjectId
        if (-not $id -or -not (Test-IsGuid $id)) { continue }
        $r = $groupLookup[$id]
        if (-not $r -or $r.Status -ne 200) {
            $msg = if ($r -and $r.Body.error.message) { $r.Body.error.message } else { 'no response' }
            & $setRow $row 'Invalid' "Distribution list not found in Entra ($msg)"
            continue
        }
        $g = $r.Body
        $isDistributionList = $g.mailEnabled -eq $true -and $g.securityEnabled -eq $false -and (@($g.groupTypes) -notcontains 'Unified')
        if (-not $isDistributionList) {
            & $setRow $row 'Invalid' 'Group is not a distribution list'
            continue
        }
        if ($g.onPremisesSyncEnabled -eq $true) {
            & $setRow $row 'Invalid' 'Synced from on-premises - Exchange Online cannot manage its membership'
        }
        if (-not $g.mail) {
            & $setRow $row 'Invalid' 'Distribution list has no primary SMTP address'
        }
        $row.DisplayName           = $g.displayName
        $row.PrimarySmtpAddress    = $g.mail
        $row.OnPremisesSyncEnabled = [bool]$g.onPremisesSyncEnabled
    }

    # --- EXISTING ACCESS PACKAGES ---------------------------------------------
    # One paged read of every access package (with catalog) instead of one GET
    # per row. Gives us: ids that no longer exist, ids in another catalog, and
    # same-name packages to link to instead of creating duplicates.
    Write-Host "`n--- EXISTING ACCESS PACKAGES ---" -ForegroundColor Cyan
    try {
        $allPackages = @(Get-GraphPagedResult -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages?`$expand=catalog")
    }
    catch {
        Write-Error -Message "Failed to read existing access packages. $($_.Exception.Message)" -Category ReadError
        return
    }
    $packageById = @{}
    $catalogPackagesByName = @{}
    foreach ($p in $allPackages) {
        $packageById[$p.id] = $p
        if ($p.catalog.id -eq $catalog.id) {
            $key = "$($p.displayName)".Trim().ToLowerInvariant()
            if (-not $catalogPackagesByName.ContainsKey($key)) { $catalogPackagesByName[$key] = @() }
            $catalogPackagesByName[$key] += $p
        }
    }
    Write-Host "$(@($allPackages | Where-Object { $_.catalog.id -eq $catalog.id }).Count) existing access package(s) in '$($catalog.displayName)'." -ForegroundColor Green

    # --- PLAN ----------------------------------------------------------------
    # One plan per access package name. Several rows (distribution lists) can
    # point at the same package - it's created/updated once.
    $validRows = @($included | Where-Object { $_.Status -ne 'Invalid' })
    $plans = @()
    foreach ($grp in ($validRows | Group-Object { (& $text $_.AccessPackageDisplayName).ToLowerInvariant() })) {
        $groupRows = @($grp.Group)
        $name = & $text $groupRows[0].AccessPackageDisplayName
        $descriptions = @($groupRows | ForEach-Object { & $text $_.AccessPackageDescription } | Select-Object -Unique)
        $ids = @($groupRows | ForEach-Object { & $text $_.AccessPackageId } | Where-Object { $_ } | Select-Object -Unique)

        $plan = [PSCustomObject]@{
            Key         = $grp.Name
            Name        = $name
            Description = $descriptions[0]
            Rows        = $groupRows
            Id          = $null
            Action      = $null
            Message     = $null
            Patch       = @{}
        }

        # Select-Object -Unique is case-sensitive on strings, which is what we
        # want here: a description that only differs in casing IS a difference
        if ($descriptions.Count -gt 1) {
            $plan.Action = 'Invalid'
            $plan.Message = "Same access package name has $($descriptions.Count) different descriptions"
        }
        elseif ($ids.Count -gt 1) {
            $plan.Action = 'Invalid'
            $plan.Message = "Same access package name has $($ids.Count) different AccessPackageIds"
        }
        elseif ($ids.Count -eq 1) {
            $plan.Id = $ids[0]
            $existing = $packageById[$plan.Id]
            if (-not $existing) {
                $plan.Action = 'NotFound'
                $plan.Message = 'AccessPackageId not found in the tenant'
            }
            elseif ($existing.catalog.id -ne $catalog.id) {
                $plan.Action = 'CatalogMismatch'
                $plan.Message = "Access package is in catalog '$($existing.catalog.displayName)' - moving catalogs isn't supported"
            }
            else {
                if ($existing.displayName -cne $name) {
                    # A rename must not collide with another package in the catalog
                    $clash = @($catalogPackagesByName[$plan.Key] | Where-Object { $_ -and $_.id -ne $plan.Id })
                    if ($clash.Count -gt 0) {
                        $plan.Action = 'Invalid'
                        $plan.Message = "Another access package in the catalog is already named '$name'"
                    }
                    else {
                        $plan.Patch.displayName = $name
                    }
                }
                if ($plan.Action -ne 'Invalid') {
                    if ("$($existing.description)".Trim() -cne $plan.Description) { $plan.Patch.description = $plan.Description }
                    $plan.Action = if ($plan.Patch.Count -gt 0) { 'Update' } else { 'Unchanged' }
                }
            }
        }
        else {
            # Where-Object { $_ } - @($null) would otherwise count as one match
            $sameName = @($catalogPackagesByName[$plan.Key] | Where-Object { $_ })
            if ($sameName.Count -gt 1) {
                $plan.Action = 'Invalid'
                $plan.Message = "$($sameName.Count) access packages in the catalog are already named '$name' - add the right AccessPackageId"
            }
            elseif ($sameName.Count -eq 1) {
                $plan.Action = 'Link'
                $plan.Id = $sameName[0].id
                if ($sameName[0].displayName -cne $name) { $plan.Patch.displayName = $name }
                if ("$($sameName[0].description)".Trim() -cne $plan.Description) { $plan.Patch.description = $plan.Description }
            }
            else {
                $plan.Action = 'Create'
            }
        }
        $plans += $plan
    }

    # The same id under two different names means the name was changed on
    # some rows but not all of them
    foreach ($dup in ($plans | Where-Object { $_.Id -and $_.Action -ne 'Invalid' } | Group-Object Id | Where-Object { $_.Count -gt 1 })) {
        foreach ($p in $dup.Group) {
            $p.Action = 'Invalid'
            $p.Message = "AccessPackageId is used with $($dup.Count) different access package names"
        }
    }

    foreach ($p in ($plans | Where-Object { $_.Action -eq 'Invalid' })) {
        foreach ($row in $p.Rows) { & $setRow $row 'Invalid' $p.Message }
    }

    # --- VALIDATION RESULT -----------------------------------------------------
    $invalidRows = @($rows | Where-Object { $_.Status -eq 'Invalid' })
    $stopReason = $null

    if ($invalidRows.Count -gt 0) {
        Write-Host "`n $($invalidRows.Count) row(s) failed validation - nothing will be created or changed:" -ForegroundColor Yellow
        foreach ($row in $invalidRows) {
            Write-Host "   Row $($row._ExcelRow) ($($row.DisplayName)): $($row.StatusMessage)" -ForegroundColor Yellow
        }
        $stopReason = 'Not processed - fix the Invalid rows and run again'
        $runError = @{ Message = "$($invalidRows.Count) row(s) failed validation - nothing was created or changed. Fix the Invalid rows and run again."; Category = 'InvalidData' }
    }

    $plans = @($plans | Where-Object { $_.Action -ne 'Invalid' })
    $changes = @($plans | Where-Object { $_.Action -eq 'Create' -or $_.Patch.Count -gt 0 })

    if (-not $stopReason) {
        Write-Host "`n Planned changes:" -ForegroundColor Cyan
        $plans | Group-Object Action | Sort-Object Name | ForEach-Object {
            Write-Host "   $($_.Name): $($_.Count)" -ForegroundColor White
        }
        if ($changes.Count -gt 0) {
            Write-Host "`n Preview of changes (first 10 of $($changes.Count)):" -ForegroundColor Cyan
            $changes | Select-Object -First 10 -Property Action, Name, @{ n = 'DistributionLists'; e = { $_.Rows.Count } }, Id |
                Format-Table -AutoSize | Out-Host
        }

        if ($changes.Count -gt $MaxPackages) {
            $stopReason = "Not processed - run exceeded -MaxPackages ($MaxPackages)"
            $runError = @{ Message = "This run would create/change $($changes.Count) access packages, which exceeds -MaxPackages ($MaxPackages). Narrow the input, or re-run with a higher -MaxPackages if this is intentional."; Category = 'LimitsExceeded' }
        }
        elseif ($preview) {
            Write-Host "`n -WhatIf: no changes were made." -ForegroundColor Yellow
            foreach ($p in $plans) {
                foreach ($row in $p.Rows) { & $setRow $row "Preview - $($p.Action)" $p.Message }
            }
        }
    }

    $runChanges = -not $stopReason -and -not $preview

    if ($runChanges -and $changes.Count -gt 0) {
        Write-Host "`n Change $($changes.Count) access package(s):" -ForegroundColor Yellow
        Write-Host "   Catalog : $($catalog.displayName)" -ForegroundColor White
        Write-Host "   Create  : $(@($changes | Where-Object Action -eq 'Create').Count)" -ForegroundColor White
        Write-Host "   Update  : $(@($changes | Where-Object Action -ne 'Create').Count)" -ForegroundColor White

        # One confirmation for the whole file. -Confirm:$false = unattended run
        if (-not $PSCmdlet.ShouldProcess("$($changes.Count) access package(s) in '$($catalog.displayName)'", 'Create or update')) {
            Write-Warning "Cancelled - no changes were made."
            $runChanges = $false
            $stopReason = 'Not processed - cancelled'
        }
    }

    # --- CREATE / UPDATE (BATCH) -----------------------------------------------
    if ($runChanges) {
        if ($changes.Count -gt 0) {
            Write-Host "`n--- CREATE / UPDATE ACCESS PACKAGES ---" -ForegroundColor Cyan
            $requests = foreach ($p in $changes) {
                if ($p.Action -eq 'Create') {
                    @{
                        CorrelationKey = $p
                        Method         = 'POST'
                        Url            = '/identityGovernance/entitlementManagement/accessPackages'
                        Body           = @{
                            displayName = $p.Name
                            description = $p.Description
                            catalog     = @{ id = $catalog.id }
                        }
                    }
                }
                else {
                    @{
                        CorrelationKey = $p
                        Method         = 'PATCH'
                        Url            = "/identityGovernance/entitlementManagement/accessPackages/$($p.Id)"
                        Body           = $p.Patch
                    }
                }
            }

            foreach ($r in (Invoke-GraphBatch -Requests @($requests) -BatchSize $BatchSize -DelayMs $DelayMs)) {
                $p = $r.CorrelationKey
                if ($r.Status -in 200, 201, 204) {
                    if ($p.Action -eq 'Create') {
                        $p.Id = $r.Body.id
                        Write-Host "  Created: $($p.Name)" -ForegroundColor Green
                    }
                    else {
                        $p.Message = "Changed: $(($p.Patch.Keys | Sort-Object) -join ', ')"
                        Write-Host "  $(if ($p.Action -eq 'Link') { 'Linked and updated' } else { 'Updated' }): $($p.Name)" -ForegroundColor Green
                    }
                }
                else {
                    $p.Message = $r.Body.error.message
                    if (-not $p.Message) { $p.Message = "HTTP $($r.Status)" }
                    if ($p.Action -eq 'Create') { $p.Id = $null }
                    $p.Action = 'Failed'
                    Write-Host "  Failed: $($p.Name) - $($p.Message)" -ForegroundColor Red
                }
            }
        }

        $statusByAction = @{
            Create          = 'Created'
            Link            = 'Linked'
            Update          = 'Updated'
            Unchanged       = 'Unchanged'
            NotFound        = 'NotFound'
            CatalogMismatch = 'CatalogMismatch'
            Failed          = 'Failed'
        }
        foreach ($p in $plans) {
            foreach ($row in $p.Rows) {
                if ($p.Id) { $row.AccessPackageId = $p.Id }
                & $setRow $row $statusByAction[$p.Action] $p.Message
            }
        }
    }
    elseif ($stopReason) {
        foreach ($row in ($rows | Where-Object { -not $_.Status })) {
            & $setRow $row 'NotProcessed' $stopReason
        }
    }

    # --- RESULTS -------------------------------------------------------------------
    Write-Host "`n Results:" -ForegroundColor Cyan
    $rows | Select-Object -Property DisplayName, AccessPackageDisplayName, AccessPackageId, Status, StatusMessage |
        Format-Table | Out-String -Width 4096 | Write-Host

    # Bicep mapping: access package id -> distribution list SMTP addresses.
    # Only rows that actually ended up with a working access package.
    $bicep = $null
    if ($BicepOutput) {
        if (-not $runChanges) {
            Write-Host " -BicepOutput skipped: no changes were run." -ForegroundColor Yellow
        }
        else {
            $escape = { param([string]$s) $s.Replace('\', '\\').Replace("'", "\'").Replace('${', '\${') }
            $mapped = @($rows | Where-Object {
                    $_.Status -in 'Created', 'Linked', 'Updated', 'Unchanged' -and $_.AccessPackageId -and $_.PrimarySmtpAddress
                })
            $lines = @(
                "// distributionListMapping - generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from $(Split-Path $ExcelPath -Leaf)"
                "// Catalog: $($catalog.displayName)"
                "// Replaces the WHOLE distributionListMapping block in main.bicepparam -"
                "// access packages that aren't in this Excel file are not included."
                "param distributionListMapping = {"
            )
            foreach ($pkg in ($mapped | Group-Object AccessPackageId | Sort-Object Name)) {
                $packageName = @($pkg.Group)[0].AccessPackageDisplayName
                $lines += "  // $packageName"
                $lines += "  '$(& $escape $pkg.Name)': ["
                foreach ($smtp in ($pkg.Group.PrimarySmtpAddress | Sort-Object -Unique)) {
                    $lines += "    '$(& $escape $smtp)'"
                }
                $lines += "  ]"
            }
            $lines += "}"
            $bicep = $lines -join "`n"

            Write-Host "`n--- BICEP: distributionListMapping ---" -ForegroundColor Cyan
            Write-Host $bicep -ForegroundColor White
        }
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $prefix = if ($preview) { 'Preview' } else { 'AccessPackages' }
    $safeName = $catalog.displayName -replace '[^\w\-]', '_'
    $exportPath = Join-Path $folderPath "$prefix-$safeName-$stamp.xlsx"
    Export-DistributionListWorkbook -Rows $rows -Path $exportPath
    Write-Host " Results exported to: $exportPath" -ForegroundColor Green

    if ($bicep) {
        $bicepPath = Join-Path $folderPath "distributionListMapping-$safeName-$stamp.bicepparam"
        Set-Content -Path $bicepPath -Value $bicep -Encoding UTF8
        Write-Host " Bicep mapping exported to: $bicepPath" -ForegroundColor Green
    }

    $summary = $rows | Group-Object Status | Sort-Object Count -Descending
    Write-Host "`n==========================================" -ForegroundColor DarkGray
    Write-Host "   OPERATION COMPLETE" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
    foreach ($s in $summary) {
        Write-Host "   $($s.Name): $($s.Count)" -ForegroundColor White
        if ($s.Name -in 'Failed', 'Invalid') {
            $errorGroups = $s.Group | Group-Object StatusMessage | Sort-Object Count -Descending
            foreach ($eg in $errorGroups) {
                $errorLabel = if ($eg.Name) { $eg.Name } else { '(no error message)' }
                Write-Host "      - $($errorLabel): $($eg.Count)" -ForegroundColor DarkYellow
            }
        }
    }

    # The same rows as in the results file, one object per distribution list
    foreach ($row in $rows) {
        $out = $row | Select-Object -Property * -ExcludeProperty '_ExcelRow'
        $out.PSObject.TypeNames.Insert(0, 'SiSGovernance.DistributionListRow')
        $out
    }

    if ($runError) {
        Write-Error -Message "$($runError.Message) Results: $exportPath" -Category $runError.Category -TargetObject $ExcelPath
    }
}
