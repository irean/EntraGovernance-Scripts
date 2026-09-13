


# ============================================================================
# UNCHANGED HELPERS
# ============================================================================

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
.PARAMETER Name
    The name of the module to verify.
.EXAMPLE
    Test-Module -Name Microsoft.Graph.Authentication
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
.EXAMPLE
    $folderPath = Select-FolderPath
#>
}


function Get-GraphUsersByFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Filter,

        [Parameter(Mandatory = $false)]
        [string]$Select = 'id,displayName,userPrincipalName',

        [Parameter(Mandatory = $false)]
        [switch]$AdvancedQuery = $true
    )

    $uri = "https://graph.microsoft.com/v1.0/users?`$filter=$Filter&`$select=$Select&`$count=true"

    Write-Host "`n Querying Graph for users matching filter:" -ForegroundColor Cyan
    Write-Host "   $Filter" -ForegroundColor White

    try {
        $users = @(igall -Uri $uri -Eventual:$AdvancedQuery)
    }
    catch {
        Write-Host "Graph query failed. Check your filter syntax." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return ,@()
    }

    if (-not $users -or $users.Count -eq 0) {
        Write-Warning "No users matched the filter."
        return ,@()
    }

    Write-Host "Found $($users.Count) matching user(s)." -ForegroundColor Green
    return ,$users
    <#
.SYNOPSIS
    Retrieves users from Microsoft Graph matching an OData $filter expression.
.PARAMETER Filter
    An OData filter expression, e.g. "department eq 'Sales'".
.PARAMETER Select
    Fields to return. Defaults to what the rest of the toolkit expects.
.PARAMETER AdvancedQuery
    Adds ConsistencyLevel: eventual, required for advanced filter operators.
.EXAMPLE
    Get-GraphUsersByFilter -Filter "userType eq 'Member' and employeeType eq 'employee'"
.REQUIRED_SCOPES
    User.Read.All
#>
}


# ============================================================================
#INTERNAL HELPERS (used by Invoke-AccessPackageAssignment)
# ============================================================================

function Connect-EntraGovernanceGraph {
    [CmdletBinding()]
    param()

    $requiredScopes = @(
        "User.Read.All",
        "EntitlementManagement.ReadWrite.All"
    )

    Write-Host "`n Connecting to Microsoft Graph..." -ForegroundColor Yellow
    Connect-MgGraph -Scopes $requiredScopes | Out-Null

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
        Write-Host "Could not verify Graph connection." -ForegroundColor Red
        return $null
    }
    Write-Host "Connected to Graph successfully as $($context.Account)." -ForegroundColor Green
    return $context
    <#
.SYNOPSIS
    Connects to Microsoft Graph with the scopes this toolkit needs and
    verifies the connection actually came up before returning.
.NOTES
    Internal helper, used by Invoke-AccessPackageAssignment.
#>
}


function Resolve-AccessPackageContext {
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
            Write-Host "Access Package found but displayName could not be read." -ForegroundColor Red
            return $null
        }
        Write-Host "Access Package : $accessPackageName" -ForegroundColor Green
    }
    catch {
        Write-Host "Access Package not found. Check the ID and your permissions." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    Write-Host "`n--- ASSIGNMENT POLICY ---" -ForegroundColor Cyan
    try {
        $policyResponse = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignmentPolicies/$AssignmentPolicyId" `
            -ErrorAction Stop

        $policyName = $policyResponse['displayName']
        if (-not $policyName) {
            Write-Host "Assignment Policy found but displayName could not be read." -ForegroundColor Red
            return $null
        }
        Write-Host "Assignment Policy : $policyName" -ForegroundColor Green
    }
    catch {
        Write-Host "Assignment Policy not found. Check the ID and your permissions." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    return [PSCustomObject]@{
        AccessPackageName    = $accessPackageName
        AssignmentPolicyName = $policyName
    }
    <#
.SYNOPSIS
    Validates an Access Package + Assignment Policy pair and returns their
    display names, or $null if either lookup fails.
.NOTES
    Internal helper, used by Invoke-AccessPackageAssignment.
#>
}


function Invoke-GraphBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,   # each: @{ CorrelationKey; Method; Url; Body (optional) }

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 5
    )

    # Sends one sub-batch (<= 20 items) and returns, per item, its SourceItem
    # (so a 429 can be resubmitted), CorrelationKey, Status, Headers, Body.
    $sendOneBatch = {
        param([array]$Items)

        $idToItem = @{}
        $batchRequests = @()
        for ($j = 0; $j -lt $Items.Count; $j++) {
            $id = "$j"
            $idToItem[$id] = $Items[$j]

            $reqObj = @{
                id     = $id
                method = $Items[$j].Method
                url    = $Items[$j].Url
            }
            if ($Items[$j].ContainsKey('Body') -and $null -ne $Items[$j].Body) {
                $reqObj.headers = @{ 'Content-Type' = 'application/json' }
                $reqObj.body = $Items[$j].Body
            }
            $batchRequests += $reqObj
        }

        $payload = @{ requests = $batchRequests } | ConvertTo-Json -Depth 10

        try {
            $batchResult = Invoke-MgGraphRequest -Method POST `
                -Uri 'https://graph.microsoft.com/v1.0/$batch' `
                -Body $payload `
                -ContentType 'application/json' `
                -ErrorAction Stop
        }
        catch {
            # Whole batch call failed (e.g. auth/network) surface it against every request in the chunk
            $out = @()
            foreach ($id in $idToItem.Keys) {
                $out += [PSCustomObject]@{
                    SourceItem     = $idToItem[$id]
                    CorrelationKey = $idToItem[$id].CorrelationKey
                    Status         = 0
                    Headers        = @{}
                    Body           = @{ error = @{ message = $_.Exception.Message } }
                }
            }
            return ,$out
        }

        $out = @()
        foreach ($resp in $batchResult.responses) {
            $item = $idToItem["$($resp.id)"]
            $out += [PSCustomObject]@{
                SourceItem     = $item
                CorrelationKey = $item.CorrelationKey
                Status         = $resp.status
                Headers        = $resp.headers
                Body           = $resp.body
            }
        }
        return ,$out
    }

    $allResponses = @()


    $chunks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Requests.Count; $i += $BatchSize) {
        $endIndex = [Math]::Min($i + $BatchSize - 1, $Requests.Count - 1)
        $chunks.Add(@($Requests[$i..$endIndex]))
    }

    $chunkNum = 0
    foreach ($chunk in $chunks) {
        $chunkNum++
        Write-Host "   Batch $chunkNum/$($chunks.Count) ($($chunk.Count) requests)..." -ForegroundColor DarkGray

        $pending = $chunk
        $attempt = 0
        $done = @()

        while ($pending.Count -gt 0) {
            $results = & $sendOneBatch $pending

            $throttled = @($results | Where-Object { $_.Status -eq 429 })
            $done += @($results | Where-Object { $_.Status -ne 429 })

            if ($throttled.Count -eq 0) { break }

            if ($attempt -ge $MaxRetries) {
                Write-Host "     Still throttled after $MaxRetries retries on $($throttled.Count) request(s) - giving up, reporting as failed." -ForegroundColor Red
                $done += $throttled
                break
            }

            $retryAfterValues = @($throttled | ForEach-Object { $_.Headers.'Retry-After' } | Where-Object { $_ })
            if ($retryAfterValues.Count -gt 0) {
                $waitSeconds = ($retryAfterValues | ForEach-Object { [int]$_ } | Sort-Object -Descending | Select-Object -First 1)
            }
            else {
                $waitSeconds = [Math]::Min(5 * [Math]::Pow(2, $attempt), 60)
            }

            Write-Host "     Throttled (429) on $($throttled.Count) request(s) - waiting $waitSeconds`s before retry $($attempt + 1)/$MaxRetries..." -ForegroundColor Yellow
            Start-Sleep -Seconds $waitSeconds

            $pending = @($throttled | ForEach-Object { $_.SourceItem })
            $attempt++
        }

        $allResponses += $done
    }

    return ,@($allResponses | ForEach-Object {
        [PSCustomObject]@{
            CorrelationKey = $_.CorrelationKey
            Status         = $_.Status
            Body           = $_.Body
        }
    })
    <#
.SYNOPSIS
    Sends an array of requests to Microsoft Graph's $batch endpoint in
    chunks of up to 20 (Graph's per-batch limit), retrying individual 429
    (throttled) items with backoff, and returns the results correlated back
    to whatever key the caller supplied.
.PARAMETER Requests
    Array of hashtables: @{ CorrelationKey = <anything>; Method = 'GET'|'POST'; Url = '/relative/path'; Body = <optional hashtable> }
.PARAMETER MaxRetries
    How many times to retry a 429'd request before giving up and reporting
    it as failed. Default 5. Each retry waits per the response's Retry-After
    header if present, otherwise an exponential backoff capped at 60s.
.OUTPUTS
    Array of PSCustomObject: CorrelationKey, Status (HTTP status, or 0 if the
    whole batch call itself failed), Body.
.NOTES
    Internal helper. Url must be relative (no host) per Graph JSON batching
    rules. A $batch call is one HTTP round trip, but each sub-request is
    still evaluated against Graph's per-endpoint throttling individually -
    batching does not exempt anything from rate limits, it only reduces
    connection overhead. entitlementManagement/assignmentRequests in
    particular is known to throttle heavily.
#>
}


function Resolve-UsersByUpn {
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

    $resolved = @()
    $notFound = @()
    foreach ($r in $responses) {
        if ($r.Status -eq 200) {
            $resolved += [PSCustomObject]@{
                id                = $r.Body.id
                displayName       = $r.Body.displayName
                userPrincipalName = $r.Body.userPrincipalName
            }
        }
        else {
            $notFound += [PSCustomObject]@{
                userPrincipalName = $r.CorrelationKey
                Error             = $r.Body.error.message
            }
        }
    }

    return [PSCustomObject]@{
        Resolved = $resolved
        NotFound = $notFound
    }
    <#
.SYNOPSIS
    Batch-resolves a list of UPNs to id/displayName/userPrincipalName via
    Microsoft Graph $batch, instead of one GET per user.
.OUTPUTS
    PSCustomObject with .Resolved (array of user objects) and .NotFound
    (array of @{userPrincipalName; Error} for UPNs that didn't resolve).
#>
}


function Resolve-AccessPackageTargetUsers {
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
                Write-Host "File not found: $ExcelPath" -ForegroundColor Red
                return $null
            }
            $rows = @(Import-Excel -Path $ExcelPath)
            if (-not $rows -or $rows.Count -eq 0) {
                Write-Warning "No users loaded from Excel."
                return $null
            }
            if (-not ($rows[0].PSObject.Properties.Name -contains 'userPrincipalName')) {
                Write-Host "Excel file must contain a 'userPrincipalName' column." -ForegroundColor Red
                Write-Host "   Columns found: $($rows[0].PSObject.Properties.Name -join ', ')" -ForegroundColor Yellow
                return $null
            }
            Write-Host "Loaded $($rows.Count) row(s) from Excel. Resolving users..." -ForegroundColor Green

            $lookup = Resolve-UsersByUpn -UserPrincipalName $rows.userPrincipalName
            $targetUsers = $lookup.Resolved
            $unresolvedFailures = $lookup.NotFound
        }

        'Filter' {
            Write-Host "`n--- RESOLVE USERS FROM FILTER ---" -ForegroundColor Cyan
            $targetUsers = Get-GraphUsersByFilter -Filter $Filter
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
    <#
.SYNOPSIS
    Normalizes the three ways of specifying target users (Excel / Filter /
    direct UPN list) into one array of {id, displayName, userPrincipalName}
    objects, plus a list of any UPNs that couldn't be resolved.
#>
}


function Resolve-AccessPackageAssignmentIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [array]$UserList
    )

    # state eq 'Delivered' matters here: without it, Graph's list includes
    # expired assignments alongside current ones, and an expired assignment's
    # id is not something adminRemove should be pointed at.
    $uri = "https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement/assignments?`$filter=accessPackage/id eq '$AccessPackageId' and state eq 'Delivered'&`$expand=target&`$select=id,target&`$count=true"

    try {
        $assignments = @(igall -Uri $uri -Eventual)
    }
    catch {
        Write-Host "Failed to look up existing assignments for removal." -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
        return [PSCustomObject]@{ Resolved = @(); NotFound = @($UserList) }
    }

    # Build a lookup of target user id -> assignment id from every current
    # assignment on this access package, one query instead of one per user.
    $lookup = @{}
    foreach ($a in $assignments) {
        $targetId = $null
        if ($a.target) {
            if ($a.target.id) { $targetId = $a.target.id }
            elseif ($a.target.objectId) { $targetId = $a.target.objectId }
        }
        if ($targetId) { $lookup[$targetId] = $a.id }
    }

    $resolved = @()
    $notFound = @()
    foreach ($user in $UserList) {
        if ($lookup.ContainsKey($user.id)) {
            $resolved += [PSCustomObject]@{ User = $user; AssignmentId = $lookup[$user.id] }
        }
        else {
            $notFound += $user
        }
    }

    return [PSCustomObject]@{ Resolved = @($resolved); NotFound = @($notFound) }
    <#
.SYNOPSIS
    Resolves each user in $UserList to their existing accessPackageAssignment
    id for the given access package, by fetching all current assignments once
    (paginated, expanding target) instead of one GET per user.
.NOTES
    Needed only for adminRemove. Unlike adminAdd, which identifies the target
    via target.objectId/accessPackageId/assignmentPolicyId, Graph's adminRemove
    identifies the assignment to remove purely by the assignment's own id -
    there is no other way to reference it, so this lookup isn't an optional
    pre-check the way an add-side duplicate check would be.
.OUTPUTS
    PSCustomObject with .Resolved (array of {User; AssignmentId}) and
    .NotFound (users with no existing assignment - nothing to remove).
#>
}


function Invoke-AccessPackageBatchOperation {
    [CmdletBinding()]
    param(
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
        [switch]$BypassApproval,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20
    )

    $results = @()
    $toSubmit = @()

    if ($RequestType -eq 'adminRemove') {
        # adminRemove identifies the assignment to remove purely by its own
        # id (assignment.id) - Graph has no other way to reference it, so
        # this lookup is required, not an optional pre-check.
        Write-Host "`n Looking up existing assignments to resolve removal targets..." -ForegroundColor Cyan
        $lookupResult = Resolve-AccessPackageAssignmentIds -AccessPackageId $AccessPackageId -UserList $UserList

        foreach ($user in $lookupResult.NotFound) {
            Write-Host "  Not assigned (nothing to remove): $($user.userPrincipalName)" -ForegroundColor Yellow
            $results += [PSCustomObject]@{
                UserPrincipalName = $user.userPrincipalName
                DisplayName       = $user.displayName
                ObjectId          = $user.id
                Status            = 'NotAssigned'
                Error             = $null
            }
        }

        foreach ($entry in $lookupResult.Resolved) {
            $body = @{
                requestType = 'adminRemove'
                assignment  = @{ id = $entry.AssignmentId }
            }
            $toSubmit += @{
                CorrelationKey = $entry.User
                Method         = 'POST'
                Url            = '/identityGovernance/entitlementManagement/assignmentRequests'
                Body           = $body
            }
        }
    }
    else {

        foreach ($user in $UserList) {
            $body = @{
                requestType = $RequestType
                assignment  = @{
                    accessPackageId    = $AccessPackageId
                    assignmentPolicyId = $AssignmentPolicyId
                    target              = @{ objectId = $user.id }
                }
            }
            if ($BypassApproval) {
                $body.justification    = "Bulk assignment via script - approval bypassed"
                $body.isValidationOnly = $false
            }

            $toSubmit += @{
                CorrelationKey = $user
                Method         = 'POST'
                Url            = '/identityGovernance/entitlementManagement/assignmentRequests'
                Body           = $body
            }
        }
    }

    Write-Host "`n Submitting $RequestType for $($toSubmit.Count) user(s) via batch..." -ForegroundColor Cyan
    if ($BypassApproval -and $RequestType -eq 'adminAdd') {
        Write-Host "   Approval bypass is enabled." -ForegroundColor Yellow
    }

    if ($toSubmit.Count -gt 0) {
        $responses = Invoke-GraphBatch -Requests $toSubmit -BatchSize $BatchSize

        foreach ($r in $responses) {
            $user = $r.CorrelationKey
            if ($r.Status -in 200, 201, 202) {
                Write-Host "  $RequestType submitted: $($user.userPrincipalName)" -ForegroundColor Green
                $results += [PSCustomObject]@{
                    UserPrincipalName = $user.userPrincipalName
                    DisplayName       = $user.displayName
                    ObjectId          = $user.id
                    Status            = 'Submitted'
                    Error             = $null
                }
            }
            else {
                $errorCode    = $r.Body.error.code
                $errorMessage = $r.Body.error.message
                $detailCodes  = @($r.Body.error.details | ForEach-Object { $_.code })


                if ($errorCode -eq 'InvalidRequestExistingGrant') {
                    Write-Host "  Already assigned (caught at submit time): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'AlreadyAssigned'
                }
                elseif ($errorCode -eq 'InvalidRequestNoActiveGrant') {
                    Write-Host "  Not assigned (nothing to remove): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'NotAssigned'
                }
                elseif ($detailCodes -contains 'ExistingOpenRequest') {
                    Write-Host "  Open request already pending: $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'OpenRequestExists'
                }
                elseif ($errorMessage -match 'already') {
                    # Fallback for a wording/code variant we haven't seen confirmed yet.
                    Write-Host "  Already assigned (caught at submit time): $($user.userPrincipalName)" -ForegroundColor Yellow
                    $status = 'AlreadyAssigned'
                }
                else {
                    Write-Host "  Failed: $($user.userPrincipalName) - $errorMessage" -ForegroundColor Red
                    $status = 'Failed'
                }
                $results += [PSCustomObject]@{
                    UserPrincipalName = $user.userPrincipalName
                    DisplayName       = $user.displayName
                    ObjectId          = $user.id
                    Status            = $status
                    Error             = $errorMessage
                }
            }
        }
    }

    return ,$results
    <#
.SYNOPSIS
    Submits adminAdd/adminRemove requests for a list of already-resolved
    users, in batches of up to $BatchSize. adminAdd has no pre-check - every
    user is submitted and the resulting status is read entirely from Graph's
    own response. adminRemove first resolves each user's existing assignment
    id via Resolve-AccessPackageAssignmentIds, since Graph's adminRemove needs
    that id and has no other way to identify the assignment to remove; users
    with nothing to remove are reported as NotAssigned without ever being
    submitted.
.OUTPUTS
    Array of PSCustomObject: UserPrincipalName, DisplayName, ObjectId,
    Status (Submitted / AlreadyAssigned / NotAssigned / OpenRequestExists / Failed), Error.
.NOTES
    Status meanings for the non-Submitted cases
    Graph responses:
      AlreadyAssigned    - adminAdd, target already has the assignment (409 InvalidRequestExistingGrant)
      NotAssigned        - adminRemove, target has no active assignment to remove (404 InvalidRequestNoActiveGrant)
      OpenRequestExists  - a request (add or remove) for this target/access package is already pending (400 InvalidRequest / details ExistingOpenRequest)
#>
}


# ============================================================================
# PUBLIC ENTRY POINT
# ============================================================================

function Invoke-AccessPackageAssignment {
    [CmdletBinding(DefaultParameterSetName = 'Users')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [string]$AssignmentPolicyId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Excel')]
        [string]$ExcelPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Filter')]
        [string]$Filter,

        [Parameter(Mandatory = $true, ParameterSetName = 'Users')]
        [string[]]$UserPrincipalName,

        [Parameter(Mandatory = $false)]
        [switch]$AdminAdd,

        [Parameter(Mandatory = $false)]
        [switch]$AdminRemove,

        [Parameter(Mandatory = $false)]
        [switch]$BypassApproval,

        [Parameter(Mandatory = $false)]
        [int]$MaxUsers = 500,

        [Parameter(Mandatory = $false)]
        [switch]$PreviewOnly,

        [Parameter(Mandatory = $false)]
        [switch]$SkipReport,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20
    )

    if ($AdminAdd.IsPresent -eq $AdminRemove.IsPresent) {
        Write-Host "Specify exactly one of -AdminAdd or -AdminRemove." -ForegroundColor Red
        return
    }
    $requestType = if ($AdminAdd) { 'adminAdd' } else { 'adminRemove' }
    $operation = if ($AdminAdd) { 'ADD' } else { 'REMOVE' }

    Write-Host "==========================================" -ForegroundColor DarkGray
    Write-Host "   ACCESS PACKAGE ASSIGNMENT ($operation)   " -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor DarkGray

    Test-Module -Name Microsoft.Graph.Authentication
    if (-not $SkipReport -or $PSCmdlet.ParameterSetName -eq 'Excel') {
        Test-Module -Name ImportExcel
    }

    if (-not (Connect-EntraGovernanceGraph)) { return }

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
        Write-Host "`n This run would touch $($targetUsers.Count) users, which exceeds -MaxUsers ($MaxUsers)." -ForegroundColor Red
        Write-Host "   Narrow the input, or re-run with a higher -MaxUsers if this is intentional." -ForegroundColor Yellow
        return
    }

    Write-Host "`n Preview of target users (first 10 of $($targetUsers.Count)):" -ForegroundColor Cyan
    $targetUsers | Select-Object -First 10 -Property displayName, userPrincipalName | Format-Table -AutoSize | Out-Host

    if ($PreviewOnly) {
        Write-Host "`n -PreviewOnly specified: no changes were made." -ForegroundColor Yellow
        return ,$targetUsers
    }

    Write-Host "`n You are about to $operation $($targetUsers.Count) user(s):" -ForegroundColor Yellow
    Write-Host "   Package        : $($context.AccessPackageName)" -ForegroundColor White
    Write-Host "   Policy         : $($context.AssignmentPolicyName)" -ForegroundColor White
    Write-Host "   Bypass Approval: $($BypassApproval.IsPresent)" -ForegroundColor White
    $confirm = Read-Host "Type 'yes' to confirm"
    if ($confirm -ne 'yes') {
        Write-Warning "Cancelled by user."
        return
    }

    $results = Invoke-AccessPackageBatchOperation `
        -AccessPackageId $AccessPackageId `
        -AssignmentPolicyId $AssignmentPolicyId `
        -UserList $targetUsers `
        -RequestType $requestType `
        -BypassApproval:$BypassApproval `
        -BatchSize $BatchSize

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
    else {
        Write-Host " Select output folder for results export..." -ForegroundColor Yellow
        $folderPath = Select-FolderPath
        if (-not $folderPath) {
            Write-Warning "No folder selected. Results not exported."
        }
        else {
            $date = Get-Date -Format 'yyyy-MM-dd'
            $safeName = $context.AccessPackageName -replace '[^\w\-]', '_'
            $exportPath = Join-Path $folderPath "$operation-$safeName-$date.xlsx"

            $results | Export-Excel -Path $exportPath `
                -WorksheetName 'Results' `
                -TableStyle Medium2 -AutoSize -AutoFilter -FreezeTopRow -BoldTopRow `
                -TableName 'ResultsTable'

            Write-Host " Results exported to: $exportPath" -ForegroundColor Green
        }
    }


    $summary = $results | Group-Object Status | Sort-Object Count -Descending
    $summary
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

    <#
.SYNOPSIS
    Adds or removes one or more users from an Access Package, sourcing the
    target users from an Excel file, a Graph $filter query, or a plain list
    of UPNs - all through the same flow.

.DESCRIPTION
    Connects to Microsoft Graph, validates the Access Package and Assignment
    Policy, resolves the target users (batching UPN -> id lookups), and
    submits adminAdd/adminRemove requests for all of them via Graph JSON
    batching (up to 20 per HTTP call) instead of one call per user.

    Users who already have the assignment, don't have one to remove, or have
    a request already pending are reported as such (AlreadyAssigned /
    NotAssigned / OpenRequestExists) rather than a generic failure - Graph
    itself rejects each case with its own error code and that's what gets
    detected; there's no separate check beforehand. A results report is
    exported to an Excel file you choose unless -SkipReport is specified,
    in which case the results are returned to the pipeline instead.

.PARAMETER AccessPackageId
    The ObjectId of the Access Package to target.

.PARAMETER AssignmentPolicyId
    The ObjectId of the Assignment Policy within the Access Package.

.PARAMETER ExcelPath
    Path to an Excel file with a 'userPrincipalName' column. (ParameterSet 'Excel')

.PARAMETER Filter
    An OData filter expression evaluated against /v1.0/users. (ParameterSet 'Filter')

.PARAMETER UserPrincipalName
    One or more UPNs directly - the simplest option for a single user. (ParameterSet 'Users', default)

.PARAMETER AdminAdd
    Assign the target users to the Access Package. Exactly one of -AdminAdd/-AdminRemove is required.

.PARAMETER AdminRemove
    Remove the target users from the Access Package. Exactly one of -AdminAdd/-AdminRemove is required.

.PARAMETER BypassApproval
    Adds justification to attempt to bypass the assignment policy's approval step.
    Only effective if the policy itself allows bypass.

.PARAMETER MaxUsers
    Safety cap on how many users a single run may touch. Default 500.

.PARAMETER PreviewOnly
    Resolves and displays the target users, then stops before confirming or submitting anything.

.PARAMETER SkipReport
    Skip the folder picker / Excel export and just return the results object.

.PARAMETER BatchSize
    Requests per Graph $batch call. Default and max 20 (Graph's own limit).

.EXAMPLE
    # Single user, no Excel file, no report popup
    Invoke-AccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $polId `
        -UserPrincipalName "anna@epicalgroup.com" -AdminAdd -SkipReport

.EXAMPLE
    # Everyone matching a filter, preview first
    Invoke-AccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $polId `
        -Filter "userType eq 'Member' and employeeType eq 'employee'" -AdminAdd -PreviewOnly

.EXAMPLE
    # Excel-based removal, with a report
    Invoke-AccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $polId `
        -ExcelPath "C:\users.xlsx" -AdminRemove

.OUTPUTS
    Array of PSCustomObject: UserPrincipalName, DisplayName, ObjectId,
    Status (Submitted / AlreadyAssigned / NotAssigned / OpenRequestExists / Failed / Failed - User not found), Error.

.REQUIRED_SCOPES
    User.Read.All
    EntitlementManagement.ReadWrite.All

.NOTES
    Author: Sandra Saluti
    Version: 2.0
    Tags: Microsoft Graph, Entitlement Management, Access Package, Batch
#>
}