function Resolve-AccessPackageTargetUsers {
    <#
    .SYNOPSIS
        Normalizes the three ways of specifying target users (Excel / Filter /
        direct UPN list) into one array of {id, displayName, userPrincipalName}
        objects, plus a list of any UPNs that couldn't be resolved.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Excel', 'Filter', 'Users')]
        [string]$Source,

        [string]$ExcelPath,
        [string]$Filter,
        [string[]]$UserPrincipalName
    )

    $unresolvedFailures = @()

    switch ($Source) {
        'Excel' {
            Write-Host "`n--- IMPORT USERS FROM EXCEL ---" -ForegroundColor Cyan
            if (-not (Test-Path $ExcelPath)) {
                Write-Error -Message "File not found: $ExcelPath" -Category ObjectNotFound -TargetObject $ExcelPath
                return $null
            }
            $rows = @(Import-Excel -Path $ExcelPath)
            if (-not $rows -or $rows.Count -eq 0) {
                Write-Warning "No users loaded from Excel."
                return $null
            }
            if (-not ($rows[0].PSObject.Properties.Name -contains 'userPrincipalName')) {
                Write-Error -Message "The Excel file must contain a 'userPrincipalName' column. Columns found: $($rows[0].PSObject.Properties.Name -join ', ')" -Category InvalidData -TargetObject $ExcelPath
                return $null
            }
            Write-Host "Loaded $($rows.Count) row(s) from Excel. Resolving users..." -ForegroundColor Green

            $lookup = Resolve-UsersByUpn -UserPrincipalName $rows.userPrincipalName
            $targetUsers = $lookup.Resolved
            $unresolvedFailures = $lookup.NotFound
        }

        'Filter' {
            Write-Host "`n--- RESOLVE USERS FROM FILTER ---" -ForegroundColor Cyan
            $targetUsers = Get-SiSGraphUser -Filter $Filter
        }

        'Users' {
            Write-Host "`n--- RESOLVE USER(S) ---" -ForegroundColor Cyan
            Write-Host "Resolving $($UserPrincipalName.Count) user(s)..." -ForegroundColor Green
            $lookup = Resolve-UsersByUpn -UserPrincipalName $UserPrincipalName
            $targetUsers = $lookup.Resolved
            $unresolvedFailures = $lookup.NotFound
        }
    }

    foreach ($f in $unresolvedFailures) {
        Write-Host "  Could not resolve user: $($f.userPrincipalName) - Skipping." -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        TargetUsers = @($targetUsers)
        NotFound    = @($unresolvedFailures)
    }
}
