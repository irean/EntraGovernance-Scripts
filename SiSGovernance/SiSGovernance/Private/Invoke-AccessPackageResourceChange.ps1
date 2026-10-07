function Invoke-AccessPackageResourceChange {
    <#
    .SYNOPSIS
        Shared engine behind Add-SiSAccessPackageResource and
        Remove-SiSAccessPackageResource: reads every package first, shows one
        preview, confirms once, then changes.
    .NOTES
        Internal helper.
    #>

    [OutputType('SiSGovernance.ResourceChangeResult')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Add', 'Remove')]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string[]]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [object]$Spec
    )

    $baseUri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement"
    $operation = $Action.ToUpper()

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   $operation ACCESS PACKAGE RESOURCE   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    if (-not (Confirm-GraphConnection -Scopes 'EntitlementManagement.ReadWrite.All')) { return }

    $results = [System.Collections.Generic.List[object]]::new()
    $newResult = {
        param($package, [string]$status, [string]$message, [string]$resourceName, [string]$roleName)
        [PSCustomObject]@{
            PSTypeName        = 'SiSGovernance.ResourceChangeResult'
            AccessPackageId   = $package.Id
            AccessPackageName = $package.Name
            ResourceType      = $Spec.Type
            Resource          = if ($resourceName) { $resourceName } else { $Spec.OriginId }
            Role              = if ($roleName) { $roleName } else { $Spec.RoleName }
            Status            = $status
            Error             = $message
        }
    }

    # --- PLAN: read everything first, change nothing ----------------------------
    Write-Host "`n--- ACCESS PACKAGES ---" -ForegroundColor Cyan
    $plans = [System.Collections.Generic.List[object]]::new()
    $catalogLookups = @{}

    foreach ($id in $AccessPackageId) {
        $state = Get-AccessPackageResourceState -AccessPackageId $id
        if ($state.Error) {
            $results.Add((& $newResult ([PSCustomObject]@{ Id = $id; Name = $null }) 'Failed' $state.Error))
            Write-Host "  Not found: $id" -ForegroundColor Red
            continue
        }
        $package = [PSCustomObject]@{ Id = $id; Name = $state.Package['displayName'] }
        Write-Host "  $($package.Name) (catalog: $($state.CatalogName))" -ForegroundColor Green

        # One catalog lookup per catalog, even if many packages are piped in
        if (-not $catalogLookups.ContainsKey($state.CatalogId)) {
            $catalogLookups[$state.CatalogId] = Get-CatalogResource -CatalogId $state.CatalogId -Spec $Spec
        }
        $lookup = $catalogLookups[$state.CatalogId]

        # What the package already grants for THIS resource. Role originId alone
        # isn't unique (SharePoint roles are '3', '4'...), so match the scope too.
        $existing = @($state.ResourceRoleScopes | Where-Object {
                $_.scope.originId -eq $Spec.OriginId -and
                ((-not $Spec.RoleOriginId -and ($_.role.displayName -eq $Spec.RoleName -or $_.role.originId -eq $Spec.RoleName)) -or
                ($Spec.RoleOriginId -and $_.role.originId -eq $Spec.RoleOriginId))
            })

        $plan = [PSCustomObject]@{
            Package     = $package
            CatalogId   = $state.CatalogId
            CatalogName = $state.CatalogName
            Existing    = $existing
            Lookup      = $lookup
            Action      = $null
            Message     = $null
        }

        if ($Action -eq 'Add') {
            if ($existing.Count -gt 0) {
                $plan.Action = 'AlreadyAdded'
            }
            elseif (-not $lookup.Resource) {
                # Role can only be checked once the resource is in the catalog
                $plan.Action = 'AddToCatalogAndPackage'
            }
            else {
                $roleCheck = Find-AccessPackageResourceRole -Spec $Spec -Roles $lookup.Roles
                if ($roleCheck.Error) {
                    $plan.Action = 'Invalid'
                    $plan.Message = $roleCheck.Error
                }
                else {
                    $plan.Action = 'Add'
                }
            }
        }
        else {
            $plan.Action = if ($existing.Count -gt 0) { 'Remove' } else { 'NotOnPackage' }
        }
        $plans.Add($plan)
    }

    foreach ($p in ($plans | Where-Object { $_.Action -in 'AlreadyAdded', 'NotOnPackage', 'Invalid' })) {
        $status = switch ($p.Action) { 'AlreadyAdded' { 'AlreadyAdded' } 'NotOnPackage' { 'NotOnPackage' } default { 'Failed' } }
        $results.Add((& $newResult $p.Package $status $p.Message))
    }
    $toChange = @($plans | Where-Object { $_.Action -in 'Add', 'AddToCatalogAndPackage', 'Remove' })

    if ($toChange.Count -gt 0) {
        Write-Host "`n $Action on $($toChange.Count) access package(s):" -ForegroundColor Yellow
        Write-Host "   Resource : $($Spec.Type) - $($Spec.OriginId)" -ForegroundColor White
        Write-Host "   Role     : $($Spec.RoleName)" -ForegroundColor White
        foreach ($p in $toChange) {
            $note = if ($p.Action -eq 'AddToCatalogAndPackage') { '  (resource is added to the catalog first)' } else { '' }
            Write-Host "   - $($p.Package.Name)$note" -ForegroundColor White
        }
        if ($Action -eq 'Add') {
            Write-Host "   Everyone already assigned to these packages gets this role." -ForegroundColor Yellow
        }
        else {
            Write-Host "   Everyone assigned to these packages loses this role." -ForegroundColor Yellow
        }

        # One confirmation for all packages, also when many are piped in
        $target = "$($Spec.Type) $($Spec.OriginId) ($($Spec.RoleName)) on $($toChange.Count) access package(s)"
        if (-not $PSCmdlet.ShouldProcess($target, "$Action resource role")) {
            if (-not $WhatIfPreference) { Write-Warning "Cancelled - no changes were made." }
            foreach ($p in $toChange) {
                $rowStatus = if ($WhatIfPreference) { "Preview - $($p.Action)" } else { 'Cancelled' }
                $results.Add((& $newResult $p.Package $rowStatus $null))
            }
            $toChange = @()
        }
    }

    # --- CHANGE --------------------------------------------------------------------
    if ($toChange.Count -gt 0) {
        Write-Host "`n--- $operation RESOURCE ---" -ForegroundColor Cyan
    }
    foreach ($p in $toChange) {
        if ($Action -eq 'Remove') {
            $ok = $true
            foreach ($rrs in $p.Existing) {
                try {
                    Invoke-MgGraphRequest -Method DELETE -Uri "$baseUri/accessPackages/$($p.Package.Id)/resourceRoleScopes/$($rrs.id)" -ErrorAction Stop | Out-Null
                }
                catch {
                    $ok = $false
                    $results.Add((& $newResult $p.Package 'Failed' $_.Exception.Message $rrs.role.resource.displayName $rrs.role.displayName))
                    Write-Host "  Failed: $($p.Package.Name) - $($_.Exception.Message)" -ForegroundColor Red
                }
            }
            if ($ok) {
                $results.Add((& $newResult $p.Package 'Removed' $null $p.Existing[0].role.resource.displayName $p.Existing[0].role.displayName))
                Write-Host "  Removed from: $($p.Package.Name)" -ForegroundColor Green
            }
            continue
        }

        # Add: make sure the resource is in this package's catalog (once per catalog)
        $lookup = $p.Lookup
        if (-not $lookup.Resource) {
            $lookup = Get-CatalogResource -CatalogId $p.CatalogId -Spec $Spec -AddIfMissing
            $catalogLookups[$p.CatalogId] = $lookup
            foreach ($other in $toChange) { if ($other.CatalogId -eq $p.CatalogId) { $other.Lookup = $lookup } }
            if ($lookup.Error) {
                $results.Add((& $newResult $p.Package 'Failed' $lookup.Error))
                Write-Host "  Failed: $($p.Package.Name) - $($lookup.Error)" -ForegroundColor Red
                continue
            }
            if ($lookup.AddedToCatalog) {
                Write-Host "  Added to catalog '$($p.CatalogName)': $($lookup.Resource.displayName)" -ForegroundColor Green
            }
        }

        $roleCheck = Find-AccessPackageResourceRole -Spec $Spec -Roles $lookup.Roles
        if ($roleCheck.Error) {
            $results.Add((& $newResult $p.Package 'Failed' $roleCheck.Error $lookup.Resource.displayName))
            Write-Host "  Failed: $($p.Package.Name) - $($roleCheck.Error)" -ForegroundColor Red
            continue
        }
        $role = $roleCheck.Role
        $scope = @($lookup.Resource.scopes | Where-Object { $_.isRootScope -eq $true }) + @($lookup.Resource.scopes) | Select-Object -First 1

        $roleBody = @{
            originId     = $role.originId
            displayName  = $role.displayName
            originSystem = $Spec.OriginSystem
            resource     = @{
                id           = $lookup.Resource.id
                originId     = $lookup.Resource.originId
                originSystem = $Spec.OriginSystem
            }
        }
        # Group roles come back with an all-zero id - Graph wants no id then
        if ($role.id -and $role.id -ne '00000000-0000-0000-0000-000000000000') { $roleBody.id = $role.id }

        $scopeBody = @{
            originId     = if ($scope) { $scope.originId } else { $lookup.Resource.originId }
            originSystem = $Spec.OriginSystem
            isRootScope  = $true
        }
        if ($scope -and $scope.id) { $scopeBody.id = $scope.id }

        $body = @{ role = $roleBody; scope = $scopeBody } | ConvertTo-Json -Depth 6
        try {
            Invoke-MgGraphRequest -Method POST -Uri "$baseUri/accessPackages/$($p.Package.Id)/resourceRoleScopes" `
                -Body $body -ContentType 'application/json' -ErrorAction Stop | Out-Null
            $results.Add((& $newResult $p.Package 'Added' $null $lookup.Resource.displayName $role.displayName))
            Write-Host "  Added to: $($p.Package.Name)" -ForegroundColor Green
        }
        catch {
            $results.Add((& $newResult $p.Package 'Failed' $_.Exception.Message $lookup.Resource.displayName $role.displayName))
            Write-Host "  Failed: $($p.Package.Name) - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host "`n==========================================" -ForegroundColor DarkGray
    Write-Host "   OPERATION COMPLETE" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
    foreach ($s in ($results | Group-Object Status | Sort-Object Count -Descending)) {
        Write-Host "   $($s.Name): $($s.Count)" -ForegroundColor White
    }

    # One object per package, so the output can be piped on (Format-Table, Export-Excel...)
    $results.ToArray()
}
