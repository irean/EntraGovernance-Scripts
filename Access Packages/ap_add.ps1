function Test-Module {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String]$Name
    )

    Write-Host "Checking module '$Name'..." -ForegroundColor Cyan
    if (-not (Get-Module $Name)) {
        Write-Host "Module '$Name' not imported, attempting import..." -ForegroundColor Yellow
        try {
            if ($Name -eq 'Microsoft.Graph') {
                Write-Host "Importing Microsoft.Graph (this may take a while)..."
            }
            Import-Module $Name -ErrorAction Stop
        }
        catch {
            Write-Host "Module '$Name' not found. Installing..." -ForegroundColor Red
            Install-Module $Name -Scope CurrentUser -AllowClobber -Force -AcceptLicense -SkipPublisherCheck
            Write-Host "Importing module '$Name' after install..." -ForegroundColor Cyan
            Import-Module $Name -ErrorAction Stop
        }
    }
    else {
        Write-Host "Module '$Name' is already imported." -ForegroundColor Green
    }
    <#
.SYNOPSIS
    Verifies and imports required PowerShell modules.

.DESCRIPTION
    This function checks whether a specified module is imported.
    If not, it attempts to import or install it as needed.

.PARAMETER Name
    The name of the module to verify.

.EXAMPLE
    Test-Module -Name Microsoft.Graph.Authentication

.NOTES
    Required for most Microsoft Graph operations.
#>
}


function ConvertTo-PSCustomObject {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [System.Collections.Hashtable] $InputObject
    )
    Process {
        if ($InputObject) {
            $o = New-Object psobject
            foreach ($key in $InputObject.Keys) {
                $value = $InputObject[$key]
                if ($value -and $value.GetType().FullName -match 'System.Object\[\]') {
                    if ($value.Count -gt 0 -and $value[0].GetType().FullName -match 'System.Collections.Hashtable') {
                        $tempVal = $value | ConvertTo-PSCustomObject
                        Add-Member -InputObject $o -NotePropertyName $key -NotePropertyValue $tempVal
                    }
                    elseif ($value.Count -gt 0 -and $value[0].GetType().FullName -match 'System.String') {
                        $tempVal = $value | ForEach-Object { $_ }
                        Add-Member -InputObject $o -NotePropertyName $key -NotePropertyValue $tempVal
                    }
                }
                elseif ($value -and $value.GetType().FullName -match 'System.Collections.Hashtable') {
                    Add-Member -InputObject $o -NotePropertyName $key -NotePropertyValue (ConvertTo-PSCustomObject -InputObject $value)
                }
                else {
                    Add-Member -InputObject $o -NotePropertyName $key -NotePropertyValue $value
                }
            }
            Write-Output $o
        }
    }
}


function igall {
    [CmdletBinding()]
    param (
        [string]$Uri,
        [switch]$Eventual,
        [int]$limit = 1000
    )
    $nextUri = $Uri
    $count = 0
    $headers = @{
        Accept = 'application/json'
    }
    if ($Eventual) {
        $headers.Add('ConsistencyLevel', 'eventual')
    }
    do {
        $result = Invoke-MgGraphRequest -Method GET -Uri $nextUri -Headers $headers
        $nextUri = $result.'@odata.nextLink'
        if ($result.value) {
            $result.value | ConvertTo-PSCustomObject
        }
        elseif ($result.value -and $result.value.GetType().FullName -match 'System.Object\[\]') {
            @()
        }
        elseif ($result) {
            $result | ConvertTo-PSCustomObject
        }
        $count += 1
    } while ($nextUri -and ($count -lt $limit))
}


function Select-FolderPath {
    [CmdletBinding()]
    param()

    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Please select a folder where the report will be saved." -ForegroundColor Cyan
    Write-Host "The folder selection window may appear behind other open windows." -ForegroundColor Yellow
    Write-Host "If you don't see it, try minimizing other windows." -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray

    Add-Type -AssemblyName System.Windows.Forms

    $FileBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
        Description         = "Select a folder for the report export"
        RootFolder          = [Environment+SpecialFolder]::Desktop
        ShowNewFolderButton = $true
    }

    $form = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    $result = $FileBrowser.ShowDialog($form)

    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $folder = $FileBrowser.SelectedPath
        Write-Host "Export folder selected: $folder" -ForegroundColor Green
        return $folder
    }
    else {
        Write-Host "No folder selected. Exiting script." -ForegroundColor Red
        return $null
    }
    <#
.SYNOPSIS
    Opens a folder picker dialog for selecting an export folder.

.DESCRIPTION
    Displays a Windows folder selection dialog and returns the chosen path.
    The dialog is forced to the top of the screen to prevent it from opening
    behind other windows.

.EXAMPLE
    $folderPath = Select-FolderPath

.RETURNS
    [string] The selected folder path, or $null if cancelled.
#>
}


function Invoke-AccessPackageOperation {
    [CmdletBinding()]
    param (
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
        [switch]$BypassApproval
    )

    $totalUsers = $UserList.Count
    $results = @()
    $successCount = 0
    $failCount = 0

    Write-Host "`n Starting $RequestType for $totalUsers users..." -ForegroundColor Cyan
    if ($BypassApproval) {
        Write-Host "   Approval bypass is enabled." -ForegroundColor Yellow
    }

    for ($i = 0; $i -lt $totalUsers; $i++) {
        $user = $UserList[$i]
        $upn = $user.userPrincipalName
        $progressPercent = [math]::Round((($i + 1) / $totalUsers) * 100, 2)

        Write-Progress -Activity "$RequestType users in Access Package" `
            -Status "Processing $upn ($($i + 1)/$totalUsers)" `
            -PercentComplete $progressPercent

        # Resolve user from UPN
        try {
            $graphUser = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/users/$($upn)?`$select=id,displayName,userPrincipalName" `
                -ErrorAction Stop
        }
        catch {
            Write-Host "  Could not resolve user: $upn - Skipping." -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                UserPrincipalName = $upn
                DisplayName       = $null
                ObjectId          = $null
                Status            = 'Failed - User not found'
                Error             = $_.Exception.Message
            }
            $failCount++
            continue
        }

        # Build request body
        $body = @{
            requestType = $RequestType
            assignment  = @{
                accessPackageId    = $AccessPackageId
                assignmentPolicyId = $AssignmentPolicyId
                target             = @{
                    objectId = $graphUser['id']
                }
            }
        }

        if ($BypassApproval) {
            $body.justification   = "Bulk assignment via script - approval bypassed"
            $body.isValidationOnly = $false
        }

        $bodyJson = $body | ConvertTo-Json -Depth 5

        # Submit request
        try {
            Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentRequests" `
                -Body $bodyJson `
                -ContentType "application/json" `
                -ErrorAction Stop | Out-Null

            Write-Host "  $RequestType submitted: $upn" -ForegroundColor Green
            $results += [PSCustomObject]@{
                UserPrincipalName = $upn
                DisplayName       = $graphUser['displayName']
                ObjectId          = $graphUser['id']
                Status            = 'Submitted'
                Error             = $null
            }
            $successCount++
        }
        catch {
            Write-Host "  Failed: $upn - $($_.Exception.Message)" -ForegroundColor Red
            $results += [PSCustomObject]@{
                UserPrincipalName = $upn
                DisplayName       = $graphUser['displayName']
                ObjectId          = $graphUser['id']
                Status            = 'Failed'
                Error             = $_.Exception.Message
            }
            $failCount++
        }
    }

    Write-Progress -Activity "$RequestType users in Access Package" -Completed
    Write-Host "`n Operation complete." -ForegroundColor Cyan
    Write-Host "   Submitted: $successCount" -ForegroundColor Green
    Write-Host "   Failed:    $failCount" -ForegroundColor Yellow

    return $results
    <#
.SYNOPSIS
    Submits adminAdd or adminRemove requests for a list of users against an Access Package.

.DESCRIPTION
    Invoke-AccessPackageOperation resolves each user by UPN against Microsoft Graph
    and submits the specified request type for each one. Failures are captured per
    user and do not stop the overall operation.

    When -BypassApproval is specified, the request body includes justification to
    signal that approval should be skipped. Note that bypass only takes effect if
    the assignment policy actually permits it — if the policy enforces mandatory
    approval this will still go through the approval flow.

.PARAMETER AccessPackageId
    The ObjectId of the Access Package.

.PARAMETER AssignmentPolicyId
    The ObjectId of the Assignment Policy.

.PARAMETER UserList
    Array of user objects with a 'userPrincipalName' property.

.PARAMETER RequestType
    Either 'adminAdd' or 'adminRemove'.

.PARAMETER BypassApproval
    When specified, adds justification to the request body to attempt to bypass
    the approval workflow.

.INPUTS
    System.Array

.OUTPUTS
    System.Management.Automation.PSCustomObject
        Each object includes:
          - UserPrincipalName
          - DisplayName
          - ObjectId
          - Status
          - Error

.REQUIRED_SCOPES
    EntitlementManagement.ReadWrite.All
    User.Read.All

.NOTES
    Author: Sandra Saluti
    Version: 1.1
    Tags: Microsoft Graph, Entitlement Management, Access Package
    Date: 2025-11-10
#>
}


function Start-BulkAddUsersToAccessPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentPolicyId,

        [Parameter(Mandatory = $true)]
        [string]$ExcelPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Add')]
        [switch]$AdminAdd,

        [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
        [switch]$AdminRemove,

        [Parameter(Mandatory = $false)]
        [switch]$BypassApproval
    )

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   BULK USER ACCESS PACKAGE OPERATION    " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    # --- Ensure required modules ---
    Test-Module -Name Microsoft.Graph.Authentication
    Test-Module -Name ImportExcel

    # --- Connect to Microsoft Graph ---
    $requiredScopes = @(
        "User.Read.All",
        "EntitlementManagement.ReadWrite.All"
    )

    Write-Host "`n Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes $requiredScopes | Out-Null

    # Verify connection is actually ready before proceeding
    $context = $null
    $retries = 0
    do {
        $context = Get-MgContext
        if (-not $context) {
            Start-Sleep -Seconds 2
            $retries++
        }
    } while (-not $context -and $retries -lt 5)

    if (-not $context) {
        Write-Host "Could not verify Graph connection. Exiting." -ForegroundColor Red
        return
    }
    Write-Host "Connected to Graph successfully as $($context.Account)." -ForegroundColor Green

    # --- Validate Access Package ---
    Write-Host "`n--- ACCESS PACKAGE ---" -ForegroundColor Cyan
    try {
        $accessPackageResponse = Invoke-MgGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/accessPackages/$AccessPackageId" `
            -ErrorAction Stop

        $accessPackageName = $accessPackageResponse['displayName']

        if (-not $accessPackageName) {
            Write-Host "Access Package found but displayName could not be read." -ForegroundColor Red
            return
        }

        Write-Host "Access Package : $accessPackageName" -ForegroundColor Green
    }
    catch {
        Write-Host "Access Package not found. Check the ID and your permissions." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    # --- Validate Assignment Policy ---
    Write-Host "`n--- ASSIGNMENT POLICY ---" -ForegroundColor Cyan
    try {
        $policyResponse = Invoke-MgGraphRequest `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$AssignmentPolicyId" `
            -ErrorAction Stop

        $policyName = $policyResponse['displayName']

        if (-not $policyName) {
            Write-Host "Assignment Policy found but displayName could not be read." -ForegroundColor Red
            return
        }

        Write-Host "Assignment Policy : $policyName" -ForegroundColor Green
    }
    catch {
        Write-Host "Assignment Policy not found. Check the ID and your permissions." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return
    }

    # --- Import users from Excel ---
    Write-Host "`n--- IMPORT USERS FROM EXCEL ---" -ForegroundColor Cyan

    if (-not (Test-Path $ExcelPath)) {
        Write-Host "File not found: $ExcelPath" -ForegroundColor Red
        return
    }

    $users = Import-Excel -Path $ExcelPath

    if (-not $users) {
        Write-Warning "No users loaded from Excel. Exiting."
        return
    }

    if (-not ($users[0].PSObject.Properties.Name -contains 'userPrincipalName')) {
        Write-Host "Excel file must contain a 'userPrincipalName' column." -ForegroundColor Red
        Write-Host "   Columns found: $($users[0].PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
        return
    }

    Write-Host "Loaded $($users.Count) users from Excel." -ForegroundColor Green

    # --- Confirm before proceeding ---
    $operation = if ($AdminAdd) { "ADD" } else { "REMOVE" }
    Write-Host "`n You are about to $operation $($users.Count) users:" -ForegroundColor Yellow
    Write-Host "   Package        : $accessPackageName" -ForegroundColor White
    Write-Host "   Policy         : $policyName" -ForegroundColor White
    Write-Host "   Bypass Approval: $($BypassApproval.IsPresent)" -ForegroundColor White
    $confirm = Read-Host "Type 'yes' to confirm"

    if ($confirm -ne 'yes') {
        Write-Warning "Cancelled by user."
        return
    }

    # --- Run operation ---
    $requestType = if ($AdminAdd) { "adminAdd" } else { "adminRemove" }
    $results = Invoke-AccessPackageOperation `
        -AccessPackageId $AccessPackageId `
        -AssignmentPolicyId $AssignmentPolicyId `
        -UserList $users `
        -RequestType $requestType `
        -BypassApproval:$BypassApproval

    # --- Export results to Excel ---
    Write-Host "`n Select output folder for results export..." -ForegroundColor Yellow
    $folderPath = Select-FolderPath
    if (-not $folderPath) {
        Write-Warning "No folder selected. Results not exported."
        return
    }

    $date = Get-Date -Format 'yyyy-MM-dd'
    $safeName = $accessPackageName -replace '[^\w\-]', '_'
    $exportPath = Join-Path $folderPath "$operation-$safeName-$date.xlsx"

    $results | Export-Excel -Path $exportPath `
        -WorksheetName 'Results' `
        -TableStyle Medium2 -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow `
        -TableName 'ResultsTable'

    Write-Host "Results exported to: $exportPath" -ForegroundColor Green

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   OPERATION COMPLETE                    " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray
    <#
.SYNOPSIS
    Bulk adds or removes users to/from an Access Package via Microsoft Graph.

.DESCRIPTION
    Start-BulkAddUsersToAccessPackage connects to Microsoft Graph, validates the
    provided Access Package and Assignment Policy, imports users from an Excel file,
    and performs either an adminAdd or adminRemove operation for each user.

    Results are exported to an Excel file in a folder of your choosing.

.PARAMETER AccessPackageId
    The ObjectId of the Access Package to target.

.PARAMETER AssignmentPolicyId
    The ObjectId of the Assignment Policy within the Access Package.

.PARAMETER ExcelPath
    Full path to the Excel file containing users to process.
    The file must have a 'userPrincipalName' column.

.PARAMETER AdminAdd
    Switch to perform an adminAdd operation (assign users to the Access Package).
    Cannot be used together with -AdminRemove.

.PARAMETER AdminRemove
    Switch to perform an adminRemove operation (remove users from the Access Package).
    Cannot be used together with -AdminAdd.

.PARAMETER BypassApproval
    When specified, adds justification to the request body to attempt to bypass
    the approval workflow. Only effective if the assignment policy permits bypass.

.EXAMPLE
    Start-BulkAddUsersToAccessPackage `
        -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
        -AssignmentPolicyId "929sio0q99ww" `
        -ExcelPath "C:\users.xlsx" `
        

.EXAMPLE
    Start-BulkAddUsersToAccessPackage `
        -AccessPackageId "b3a77f84-6a3d-44b1-9f50-d32c17346a31" `
        -AssignmentPolicyId "929sio0q99ww" `
        -ExcelPath "C:\users.xlsx" `
        -AdminRemove `
        -BypassApproval

.INPUTS
    None. Parameters are passed directly.

.OUTPUTS
    Excel (.xlsx) file with columns:
      - UserPrincipalName
      - DisplayName
      - ObjectId
      - Status
      - Error

.REQUIRED_SCOPES
    User.Read.All
    EntitlementManagement.ReadWrite.All

.NOTES
    Author: Sandra Saluti
    Version: 1.1
    Tags: Microsoft Graph, Entitlement Management, Access Package, Bulk Assignment
    Date: 2025-11-10
#>
}