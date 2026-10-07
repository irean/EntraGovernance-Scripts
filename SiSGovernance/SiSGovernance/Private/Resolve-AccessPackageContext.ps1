function Resolve-AccessPackageContext {
    <#
    .SYNOPSIS
        Validates an Access Package + Assignment Policy pair and returns their
        display names, or writes an error and returns $null if either lookup fails.
    .NOTES
        Internal helper, used by Add-/Remove-SiSAccessPackageAssignment.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentPolicyId
    )

    Write-Host "`n--- ACCESS PACKAGE ---" -ForegroundColor Cyan
    try {
        $accessPackageResponse = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId" `
            -ErrorAction Stop

        $accessPackageName = $accessPackageResponse['displayName']
        if (-not $accessPackageName) {
            Write-Error -Message "Access package $AccessPackageId was found, but its displayName could not be read." -Category InvalidData -TargetObject $AccessPackageId
            return $null
        }
        Write-Host "Access Package : $accessPackageName" -ForegroundColor Green
    }
    catch {
        Write-Error -Message "Access package $AccessPackageId not found - check the id and your permissions. $($_.Exception.Message)" -Category ObjectNotFound -TargetObject $AccessPackageId
        return $null
    }

    Write-Host "`n--- ASSIGNMENT POLICY ---" -ForegroundColor Cyan
    try {
        $policyResponse = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$AssignmentPolicyId" `
            -ErrorAction Stop

        $policyName = $policyResponse['displayName']
        if (-not $policyName) {
            Write-Error -Message "Assignment policy $AssignmentPolicyId was found, but its displayName could not be read." -Category InvalidData -TargetObject $AssignmentPolicyId
            return $null
        }
        Write-Host "Assignment Policy : $policyName" -ForegroundColor Green
    }
    catch {
        Write-Error -Message "Assignment policy $AssignmentPolicyId not found - check the id and your permissions. $($_.Exception.Message)" -Category ObjectNotFound -TargetObject $AssignmentPolicyId
        return $null
    }

    return [PSCustomObject]@{
        AccessPackageName    = $accessPackageName
        AssignmentPolicyName = $policyName
    }
}
