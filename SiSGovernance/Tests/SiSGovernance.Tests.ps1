# ============================================================================
# Pester 5 tests for the SiSGovernance module
#
# Run from VS Code: open this file and click "Run tests" above a Describe, or
#   Invoke-Pester -Path .\Tests -Output Detailed      (from the SiSGovernance folder)
#
# Requires Pester 5 (Windows ships 3.4):
#   Install-Module Pester -Scope CurrentUser -SkipPublisherCheck
#
# No tenant needed: everything that talks to Graph is mocked. Both
# dependencies must be installed: Microsoft.Graph.Authentication (the module
# requires it, and its cmdlets are what gets mocked) and ImportExcel (the Sync
# tests write and read real Excel files in TestDrive:).
# ============================================================================

BeforeDiscovery {
    # InModuleScope below needs the module already during discovery
    Import-Module (Join-Path $PSScriptRoot '../SiSGovernance/SiSGovernance.psd1') -Force
}

# The function tests run inside the module, so private helpers can be called
# and mocked directly, and mocks of the Graph cmdlets apply to the module's calls.
InModuleScope 'SiSGovernance' {

BeforeAll {
    # Quiet and fast
    Mock Write-Host { }
    Mock Start-Sleep { }
    Mock Write-Progress { }

    # A Graph $batch response for the given requests, built by a scriptblock
    # that returns @{ status; body; headers } per request
    function New-BatchResponse {
        param([string]$Body, [scriptblock]$PerRequest)
        $requests = ($Body | ConvertFrom-Json).requests
        $responses = foreach ($req in $requests) {
            $r = & $PerRequest $req
            @{ id = $req.id; status = $r.status; body = $r.body; headers = $(if ($r.headers) { $r.headers } else { @{} }) }
        }
        @{ responses = @($responses) }
    }
}


Describe 'Test-IsGuid' {
    It 'accepts a GUID' {
        Test-IsGuid ([guid]::NewGuid().ToString()) | Should -BeTrue
    }
    It 'rejects path-like input' {
        Test-IsGuid '../../users' | Should -BeFalse
    }
    It 'rejects empty input' {
        Test-IsGuid '' | Should -BeFalse
    }
}


Describe 'Get-GraphPagedResult' {
    It 'follows @odata.nextLink and returns every item from every page' {
        Mock Invoke-MgGraphRequest -ParameterFilter { $Uri -eq 'https://graph/page1' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }, [pscustomobject]@{ id = '2' }); '@odata.nextLink' = 'https://graph/page2' }
        }
        Mock Invoke-MgGraphRequest -ParameterFilter { $Uri -eq 'https://graph/page2' } {
            [pscustomobject]@{ value = @([pscustomobject]@{ id = '3' }) }
        }

        $items = @(Get-GraphPagedResult -Uri 'https://graph/page1')

        $items.id | Should -Be @('1', '2', '3')
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'asks Graph for PSObjects, so nothing is converted by hand' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = '1'; groupTypes = @('Unified') }) } }

        $item = Get-GraphPagedResult -Uri 'https://graph/x'

        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $OutputType -eq 'PSObject' } -Times 1 -Exactly
        $item | Should -BeOfType [pscustomobject]
        # A one-element array stays an array
        , $item.groupTypes | Should -BeOfType [array]
    }

    It 'returns nothing for an empty result - not the response itself' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ '@odata.context' = 'x'; value = @() } }

        $items = @(Get-GraphPagedResult -Uri 'https://graph/x')

        $items.Count | Should -Be 0
    }

    It 'returns a single object (no value collection) as it is' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ id = 'cat-1'; displayName = 'Catalog' } }

        $item = @(Get-GraphPagedResult -Uri 'https://graph/catalogs/cat-1')

        $item.Count | Should -Be 1
        $item[0].id | Should -Be 'cat-1'
    }

    It 'warns when it stops at -MaxPages with more pages left' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }); '@odata.nextLink' = 'https://graph/next' } }

        $items = @(Get-GraphPagedResult -Uri 'https://graph/x' -MaxPages 2 -WarningVariable warnings -WarningAction SilentlyContinue)

        $items.Count | Should -Be 2
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -Match 'Stopped after 2 page'
    }

    It 'does not warn when every page was read' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) } }

        Get-GraphPagedResult -Uri 'https://graph/x' -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        $warnings.Count | Should -Be 0
    }

    It 'sends ConsistencyLevel: eventual only with -Eventual' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = '1' }) } }

        Get-GraphPagedResult -Uri 'https://graph/x' | Out-Null
        Get-GraphPagedResult -Uri 'https://graph/x' -Eventual | Out-Null

        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { -not $Headers.ContainsKey('ConsistencyLevel') } -Times 1 -Exactly
        Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Headers['ConsistencyLevel'] -eq 'eventual' } -Times 1 -Exactly
    }
}


Describe 'ConvertTo-AccessPackageResourceSpec' {
    BeforeAll { $gid = [guid]::NewGuid().ToString() }

    It 'builds the Member role for a group by default' {
        $spec = ConvertTo-AccessPackageResourceSpec -Type Group -GroupId $gid
        $spec.OriginSystem | Should -Be 'AadGroup'
        $spec.RoleOriginId | Should -Be "Member_$gid"
    }
    It 'builds the Owner role for a group' {
        (ConvertTo-AccessPackageResourceSpec -Type Group -GroupId $gid -GroupRole Owner).RoleOriginId | Should -Be "Owner_$gid"
    }
    It 'trims a trailing slash from a SharePoint URL' {
        $spec = ConvertTo-AccessPackageResourceSpec -Type SharePoint -SiteUrl 'https://contoso.sharepoint.com/sites/Sales/' -RoleName 'Members'
        $spec.OriginId | Should -Be 'https://contoso.sharepoint.com/sites/Sales'
        $spec.OriginSystem | Should -Be 'SharePointOnline'
    }
}


Describe 'Find-AccessPackageResourceRole' {
    BeforeAll {
        $roles = @(
            [pscustomobject]@{ originId = 'role-user'; displayName = 'User' }
            [pscustomobject]@{ originId = 'role-admin'; displayName = 'Admin' }
        )
        $spec = { param($name) [pscustomobject]@{ RoleName = $name; RoleOriginId = $null } }
    }

    It 'finds a role by display name' {
        (Find-AccessPackageResourceRole -Spec (& $spec 'User') -Roles $roles).Role.originId | Should -Be 'role-user'
    }
    It 'finds a role by originId' {
        (Find-AccessPackageResourceRole -Spec (& $spec 'role-admin') -Roles $roles).Role.displayName | Should -Be 'Admin'
    }
    It 'lists the available roles when the role does not exist' {
        $r = Find-AccessPackageResourceRole -Spec (& $spec 'Viewer') -Roles $roles
        $r.Role | Should -BeNullOrEmpty
        $r.Error | Should -Match 'Available: Admin, User'
    }
}


Describe 'Invoke-GraphBatch' {
    BeforeEach { $script:calls = 0; $script:payloads = @() }

    It 'splits 45 requests into 3 batch calls of max 20' {
        Mock Invoke-MgGraphRequest {
            $script:calls++
            New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{} } }
        }
        $requests = 1..45 | ForEach-Object { @{ CorrelationKey = $_; Method = 'GET'; Url = "/users/u$_" } }

        $r = Invoke-GraphBatch -Requests $requests

        $r.Count | Should -Be 45
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly
    }

    It 'sends per-request headers inside the batch' {
        Mock Invoke-MgGraphRequest {
            $script:payloads += $Body
            New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{} } }
        }
        Invoke-GraphBatch -Requests @(@{ CorrelationKey = 'a'; Method = 'GET'; Url = '/groups/g/members'; Headers = @{ ConsistencyLevel = 'eventual' } }) | Out-Null

        ($script:payloads[0] | ConvertFrom-Json).requests[0].headers.ConsistencyLevel | Should -Be 'eventual'
    }

    It 'retries a 429 and then succeeds' {
        Mock Invoke-MgGraphRequest {
            $script:calls++
            $status = if ($script:calls -eq 1) { 429 } else { 200 }
            New-BatchResponse -Body $Body -PerRequest { @{ status = $status; body = @{}; headers = @{ 'Retry-After' = '0' } } }
        }

        $r = Invoke-GraphBatch -Requests @(@{ CorrelationKey = 'a'; Method = 'GET'; Url = '/users/a' })

        $r[0].Status | Should -Be 200
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'gives up after -MaxRetries and reports the 429' {
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest { @{ status = 429; body = @{}; headers = @{ 'Retry-After' = '0' } } }
        }

        $r = Invoke-GraphBatch -Requests @(@{ CorrelationKey = 'a'; Method = 'GET'; Url = '/users/a' }) -MaxRetries 2 -WarningVariable warnings -WarningAction SilentlyContinue

        $r[0].Status | Should -Be 429
        Should -Invoke Invoke-MgGraphRequest -Times 3 -Exactly   # first try + 2 retries
        "$($warnings[0])" | Should -Match 'giving up'
    }

    It 'shows progress per batch, and the details with -Verbose' {
        Mock Invoke-MgGraphRequest { New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{} } } }
        $requests = 1..25 | ForEach-Object { @{ CorrelationKey = "$_"; Method = 'GET'; Url = "/users/$_" } }

        $verbose = Invoke-GraphBatch -Requests $requests -DelayMs 0 -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }

        Should -Invoke Write-Progress -ParameterFilter { $Status -eq 'Batch 2 of 2' } -Times 1 -Exactly
        Should -Invoke Write-Progress -ParameterFilter { $Completed } -Times 1 -Exactly
        "$verbose" | Should -Match 'Batch 1/2 \(20 requests\)'
    }

    It 'retries a GET when the batch call gets no answer' {
        Mock Invoke-MgGraphRequest {
            $script:calls++
            if ($script:calls -eq 1) { throw [System.Net.Http.HttpRequestException]::new('connection reset') }
            New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{} } }
        }

        $r = Invoke-GraphBatch -Requests @(@{ CorrelationKey = 'a'; Method = 'GET'; Url = '/users/a' })

        $r[0].Status | Should -Be 200
        Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
    }

    It 'does NOT resend a POST when the batch call gets no answer' {
        Mock Invoke-MgGraphRequest { throw [System.Net.Http.HttpRequestException]::new('connection reset') }

        $r = Invoke-GraphBatch -Requests @(@{ CorrelationKey = 'a'; Method = 'POST'; Url = '/x'; Body = @{ a = 1 } })

        $r[0].Status | Should -Be 0
        $r[0].Body.error.message | Should -Match 'outcome unknown'
        Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
    }

    It 'slows down when Graph reports 85% of the throttling limit' {
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{}; headers = @{ 'x-ms-throttle-limit-percentage' = '0.85' } } }
        }
        $requests = 1..25 | ForEach-Object { @{ CorrelationKey = $_; Method = 'GET'; Url = "/users/u$_" } }

        Invoke-GraphBatch -Requests $requests | Out-Null

        Should -Invoke Start-Sleep -ParameterFilter { $Milliseconds -eq 2000 } -Times 1 -Exactly
    }

    It 'pauses -DelayMs between batches but not after the last one' {
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest { @{ status = 200; body = @{} } }
        }
        $requests = 1..45 | ForEach-Object { @{ CorrelationKey = $_; Method = 'GET'; Url = "/users/u$_" } }

        Invoke-GraphBatch -Requests $requests -DelayMs 500 | Out-Null

        Should -Invoke Start-Sleep -ParameterFilter { $Milliseconds -eq 500 } -Times 2 -Exactly
    }
}


Describe 'Confirm-GraphConnection' {
    BeforeAll {
        Mock Connect-MgGraph { }
    }

    It 'writes an error with the Connect-MgGraph command when there is no Graph connection' {
        Mock Get-MgContext { $null }

        Confirm-GraphConnection -Scopes 'GroupMember.Read.All' -ErrorVariable err -ErrorAction SilentlyContinue | Should -BeNullOrEmpty

        $err.Count | Should -Be 1
        $err[0].CategoryInfo.Category | Should -Be 'ConnectionError'
        "$($err[0])" | Should -Match 'Connect-MgGraph -Scopes GroupMember.Read.All'
    }

    It 'throws with -ErrorAction Stop, so a caller can catch it' {
        Mock Get-MgContext { $null }

        { Confirm-GraphConnection -Scopes 'GroupMember.Read.All' -ErrorAction Stop } | Should -Throw '*Not connected*'
    }

    It 'never signs in by itself' {
        Mock Get-MgContext { $null }

        Confirm-GraphConnection -Scopes 'GroupMember.Read.All' -ErrorAction SilentlyContinue | Out-Null

        Should -Invoke Connect-MgGraph -Times 0
    }

    It 'returns the context when the token has every scope' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('GroupMember.Read.All', 'EntitlementManagement.ReadWrite.All') } }

        Confirm-GraphConnection -Scopes 'GroupMember.Read.All' | Should -Not -BeNullOrEmpty
    }

    It 'accepts a higher-privileged permission in place of the one needed' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('Group.Read.All', 'EntitlementManagement.ReadWrite.All') } }

        Confirm-GraphConnection -Scopes 'GroupMember.Read.All', 'EntitlementManagement.Read.All' | Should -Not -BeNullOrEmpty
    }

    It 'stops a signed-in user with an error when a needed scope is missing' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('GroupMember.Read.All') } }

        Confirm-GraphConnection -Scopes 'EntitlementManagement.ReadWrite.All', 'GroupMember.Read.All' -ErrorVariable err -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty

        $err[0].CategoryInfo.Category | Should -Be 'PermissionDenied'
        "$($err[0])" | Should -Match 'missing: EntitlementManagement.ReadWrite.All'
    }

    It 'only warns for an app-only connection, which may have an Entitlement Management role instead' {
        Mock Get-MgContext { [pscustomobject]@{ ClientId = 'app'; AuthType = 'AppOnly'; Scopes = @('GroupMember.Read.All') } }

        $result = Confirm-GraphConnection -Scopes 'EntitlementManagement.ReadWrite.All', 'GroupMember.Read.All' -WarningVariable warnings -WarningAction SilentlyContinue

        $result | Should -Not -BeNullOrEmpty
        $warnings.Count | Should -Be 1
    }
}


Describe 'Resolve-AccessPackageCatalog' {
    It 'writes an error when no catalog has the name - an empty result is not a catalog' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ '@odata.context' = 'x'; value = @() } }

        $catalog = Resolve-AccessPackageCatalog -CatalogName 'Does not exist' -ErrorVariable err -ErrorAction SilentlyContinue

        $catalog | Should -BeNullOrEmpty
        $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
    }

    It 'writes an error when more than one catalog has the name' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1'; displayName = 'Dup' }, [pscustomobject]@{ id = 'c2'; displayName = 'Dup' }) } }

        $catalog = Resolve-AccessPackageCatalog -CatalogName 'Dup' -ErrorVariable err -ErrorAction SilentlyContinue

        $catalog | Should -BeNullOrEmpty
        "$($err[0])" | Should -Match 'c1, c2'
    }

    It 'returns the catalog when exactly one has the name' {
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'c1'; displayName = 'Identity - Employee' }) } }

        (Resolve-AccessPackageCatalog -CatalogName 'Identity - Employee').id | Should -Be 'c1'
    }
}


Describe 'Resolve-AccessPackageContext' {
    It 'writes an error that -ErrorAction Stop turns into an exception when the access package does not exist' {
        Mock Invoke-MgGraphRequest { throw 'Response status code does not indicate success: NotFound' }

        { Resolve-AccessPackageContext -AccessPackageId 'ap' -AssignmentPolicyId 'pol' -ErrorAction Stop } |
            Should -Throw '*Access package ap not found*'
    }
}


Describe 'Add-SiSAccessPackageAssignment / Remove-SiSAccessPackageAssignment' {
    BeforeAll {
        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Resolve-AccessPackageContext { [pscustomobject]@{ AccessPackageName = 'AP'; AssignmentPolicyName = 'Policy' } }
        $common = @{
            AccessPackageId    = [guid]::NewGuid().ToString()
            AssignmentPolicyId = [guid]::NewGuid().ToString()
            SkipReport         = $true
            DelayMs            = 0
            Confirm            = $false
        }
    }

    BeforeEach {
        $script:posted = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest {
                param($req)
                if ($req.method -eq 'GET') {
                    $upn = ($req.url -replace '^/users/', '') -replace '\?.*$', ''
                    @{ status = 200; body = @{ id = "id-$upn"; displayName = $upn; userPrincipalName = $upn } }
                }
                else {
                    $script:posted.Add($req.body.assignment.target.objectId)
                    if ($req.body.assignment.target.objectId -eq 'id-already@x.com') {
                        @{ status = 409; body = @{ error = @{ code = 'InvalidRequestExistingGrant'; message = 'already has access' } } }
                    }
                    else { @{ status = 201; body = @{} } }
                }
            }
        }
    }

    It 'takes UPN strings from the pipeline and removes duplicates' {
        'a@x.com', 'b@x.com', 'a@x.com', ' c@x.com ' | Add-SiSAccessPackageAssignment @common | Out-Null

        $script:posted.Count | Should -Be 3
        $script:posted | Should -Contain 'id-c@x.com'
    }

    It 'takes objects with a userPrincipalName property from the pipeline' {
        @([pscustomobject]@{ userPrincipalName = 'd@x.com' }, [pscustomobject]@{ UserPrincipalName = 'e@x.com' }) |
            Add-SiSAccessPackageAssignment @common | Out-Null

        $script:posted | Should -Be @('id-d@x.com', 'id-e@x.com')
    }

    It 'still works with -UserPrincipalName directly' {
        Add-SiSAccessPackageAssignment @common -UserPrincipalName 'f@x.com' | Out-Null

        $script:posted | Should -Be @('id-f@x.com')
    }

    It 'does nothing for an empty pipeline' {
        @() | Add-SiSAccessPackageAssignment @common | Out-Null

        Should -Invoke Confirm-GraphConnection -Times 0
    }

    It 'Remove sends adminRemove with the existing assignment id, and skips users with nothing to remove' {
        $script:removeBodies = [System.Collections.Generic.List[object]]::new()
        Mock Resolve-AccessPackageAssignmentIds {
            [pscustomobject]@{
                Resolved = @([pscustomobject]@{ User = $UserList[0]; AssignmentId = 'asg-1' })
                NotFound = @($UserList | Select-Object -Skip 1)
            }
        }
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest {
                param($req)
                if ($req.method -eq 'GET') {
                    $upn = ($req.url -replace '^/users/', '') -replace '\?.*$', ''
                    @{ status = 200; body = @{ id = "id-$upn"; displayName = $upn; userPrincipalName = $upn } }
                }
                else {
                    $script:removeBodies.Add($req.body)
                    @{ status = 201; body = @{} }
                }
            }
        }

        'a@x.com', 'b@x.com' | Remove-SiSAccessPackageAssignment @common | Out-Null

        $script:removeBodies.Count | Should -Be 1
        $script:removeBodies[0].requestType | Should -Be 'adminRemove'
        $script:removeBodies[0].assignment.id | Should -Be 'asg-1'
    }

    Context 'the Excel report' {
        BeforeEach {
            Get-ChildItem $TestDrive | Remove-Item -Recurse -Force
            New-Item -Path "$TestDrive/reports" -ItemType Directory | Out-Null
            $report = $common.Clone()
            $report.Remove('SkipReport')
            Mock Select-FolderPath { "$TestDrive/reports" }
        }

        It '-OutputPath writes it there without a dialog, named with date and time' {
            'a@x.com' | Add-SiSAccessPackageAssignment @report -OutputPath "$TestDrive/reports" | Out-Null

            Should -Invoke Select-FolderPath -Times 0
            $files = @(Get-ChildItem "$TestDrive/reports" -Filter '*.xlsx')
            $files.Count | Should -Be 1
            $files[0].Name | Should -Match '^ADD-AP-\d{4}-\d{2}-\d{2}_\d{6}\.xlsx$'
            (Import-Excel $files[0].FullName).UserPrincipalName | Should -Be 'a@x.com'
        }

        It 'a second run the same day never overwrites the first report' {
            $script:stamps = [System.Collections.Generic.Queue[string]]::new([string[]]@('2026-10-07_101500', '2026-10-07_101501'))
            Mock Get-Date -ParameterFilter { $Format -eq 'yyyy-MM-dd_HHmmss' } { $script:stamps.Dequeue() }

            'a@x.com' | Add-SiSAccessPackageAssignment @report -OutputPath "$TestDrive/reports" | Out-Null
            'b@x.com' | Add-SiSAccessPackageAssignment @report -OutputPath "$TestDrive/reports" | Out-Null

            @(Get-ChildItem "$TestDrive/reports" -Filter '*.xlsx').Count | Should -Be 2
        }

        It 'asks for the folder first, and does nothing when the dialog is cancelled' {
            Mock Select-FolderPath { $null }

            'a@x.com' | Add-SiSAccessPackageAssignment @report | Out-Null

            Should -Invoke Confirm-GraphConnection -Times 0
            $script:posted.Count | Should -Be 0
        }

        It 'stops with an error, before anything else, when -OutputPath does not exist' {
            'a@x.com' | Add-SiSAccessPackageAssignment @report -OutputPath "$TestDrive/nope" -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null

            $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            Should -Invoke Confirm-GraphConnection -Times 0
            $script:posted.Count | Should -Be 0
        }
    }

    It 'rejects an AccessPackageId or AssignmentPolicyId that is not a GUID' {
        { Add-SiSAccessPackageAssignment -AccessPackageId 'not-a-guid' -AssignmentPolicyId $common.AssignmentPolicyId -UserPrincipalName 'a@x.com' -ErrorAction Stop } | Should -Throw
        { Add-SiSAccessPackageAssignment -AccessPackageId $common.AccessPackageId -AssignmentPolicyId '929sio0q99ww' -UserPrincipalName 'a@x.com' -ErrorAction Stop } | Should -Throw
    }

    It 'passes the ids on as lowercase GUID strings, also when given in uppercase' {
        Mock Resolve-AccessPackageAssignmentIds { [pscustomobject]@{ Resolved = @(); NotFound = @($UserList) } }
        $upper = $common.Clone()
        $upper.AccessPackageId = $common.AccessPackageId.ToUpperInvariant()
        $upper.AssignmentPolicyId = $common.AssignmentPolicyId.ToUpperInvariant()

        'a@x.com' | Add-SiSAccessPackageAssignment @upper | Out-Null
        'a@x.com' | Remove-SiSAccessPackageAssignment @upper | Out-Null

        Should -Invoke Resolve-AccessPackageContext -Times 2 -Exactly -ParameterFilter {
            $AccessPackageId -ceq $common.AccessPackageId -and $AssignmentPolicyId -ceq $common.AssignmentPolicyId
        }
    }

    It '-WhatIf submits nothing and returns a Preview result per user' {
        $results = 'a@x.com', 'b@x.com' | Add-SiSAccessPackageAssignment @common -WhatIf

        $script:posted.Count | Should -Be 0
        $results.UserPrincipalName | Should -Be @('a@x.com', 'b@x.com')
        $results.Status | Should -Be @('Preview - Add', 'Preview - Add')
        $results[0].PSObject.TypeNames[0] | Should -Be 'SiSGovernance.AssignmentResult'
    }

    It 'returns one result per user - not a summary - so it can be piped on' {
        $results = @('a@x.com', 'already@x.com' | Add-SiSAccessPackageAssignment @common)

        $results.Count | Should -Be 2
        ($results | Where-Object UserPrincipalName -eq 'a@x.com').Status | Should -Be 'Submitted'
        ($results | Where-Object UserPrincipalName -eq 'already@x.com').Status | Should -Be 'AlreadyAssigned'
        $results | ForEach-Object { $_.PSObject.TypeNames[0] | Should -Be 'SiSGovernance.AssignmentResult' }
    }

    It 'writes an error and submits nothing when the run is over -MaxUsers' {
        'a@x.com', 'b@x.com', 'c@x.com' | Add-SiSAccessPackageAssignment @common -MaxUsers 2 -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null

        $script:posted.Count | Should -Be 0
        $err[0].CategoryInfo.Category | Should -Be 'LimitsExceeded'
    }

    It 'reports users as Failed, not NotAssigned, when the assignment lookup fails' {
        Mock Resolve-AccessPackageAssignmentIds { $null }

        $result = 'a@x.com' | Remove-SiSAccessPackageAssignment @common

        $result.Status | Should -Be 'Failed'
    }
}


Describe 'Sync-SiSAccessPackage' {
    BeforeAll {
        $script:catalog = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = 'Test Catalog' }

        $script:dl1 = [guid]::NewGuid().ToString()
        $script:dl2 = [guid]::NewGuid().ToString()
        $script:groups = @{
            $script:dl1 = @{ id = $script:dl1; displayName = 'DL1'; mail = 'dl1@contoso.com'; mailEnabled = $true; securityEnabled = $false; groupTypes = @(); onPremisesSyncEnabled = $null }
            $script:dl2 = @{ id = $script:dl2; displayName = "O'Brien"; mail = "o'brien@contoso.com"; mailEnabled = $true; securityEnabled = $false; groupTypes = @(); onPremisesSyncEnabled = $null }
        }

        Mock Select-FolderPath { $TestDrive }
        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Resolve-AccessPackageCatalog { $script:catalog }

        function New-Row {
            param($ObjectId, $Include, $Name, $Description, $AccessPackageId)
            [pscustomobject]@{
                ObjectId                 = $ObjectId
                DisplayName              = ''
                PrimarySmtpAddress       = ''
                Include                  = $Include
                AccessPackageDisplayName = $Name
                AccessPackageDescription = $Description
                ScopingNotes             = ''
                AccessPackageId          = $AccessPackageId
            }
        }

        function Get-LatestResult {
            param([string]$Prefix = 'AccessPackages')
            $file = Get-ChildItem $TestDrive -Filter "$Prefix-*.xlsx" | Sort-Object LastWriteTime | Select-Object -Last 1
            @(Import-Excel $file.FullName)
        }
    }

    BeforeEach {
        Get-ChildItem $TestDrive | Remove-Item -Recurse -Force
        $script:existingPackages = @()
        $script:writes = [System.Collections.Generic.List[object]]::new()

        Mock Get-GraphPagedResult { $script:existingPackages }   # existing access packages
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest {
                param($req)
                if ($req.method -eq 'GET') {
                    $id = ($req.url -replace '^/groups/', '') -replace '\?.*$', ''
                    if ($script:groups.ContainsKey($id)) { @{ status = 200; body = $script:groups[$id] } }
                    else { @{ status = 404; body = @{ error = @{ message = 'Resource not found' } } } }
                }
                elseif ($req.method -eq 'POST') {
                    $script:writes.Add($req)
                    @{ status = 201; body = @{ id = [guid]::NewGuid().ToString() } }
                }
                else {
                    $script:writes.Add($req)
                    @{ status = 204; body = $null }
                }
            }
        }
    }

    It 'skips rows without Include = Yes and creates nothing' {
        New-Row $script:dl1 $null 'DL - Test - 1' 'Test 1' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        $result = Get-LatestResult
        $result[0].Status | Should -Be 'Skipped'
        $result[0].StatusMessage | Should -Be 'Include not set'
        $script:writes.Count | Should -Be 0
    }

    It 'handles numbers in text columns (Excel turns them into numbers)' {
        New-Row $script:dl1 'Yes' 2026 12345 $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        (Get-LatestResult)[0].Status | Should -Be 'Created'
    }

    It 'accepts yes in any casing and with spaces' {
        New-Row $script:dl1 ' YES ' 'DL - Test - 1' 'Test 1' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        (Get-LatestResult)[0].Status | Should -Be 'Created'
    }

    It 'creates ONE access package for two lists with the same name, and writes the id back to both' {
        @(
            New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null
            New-Row $script:dl2 'Yes' 'Mail - Sales' 'Sales lists' $null
        ) | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -BicepOutput -Confirm:$false

        $script:writes.Count | Should -Be 1
        $result = Get-LatestResult
        $result.Status | Should -Be @('Created', 'Created')
        $result[0].AccessPackageId | Should -Not -BeNullOrEmpty
        $result[0].AccessPackageId | Should -Be $result[1].AccessPackageId
    }

    It 'writes the Bicep mapping with SMTP addresses and escapes apostrophes' {
        @(
            New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null
            New-Row $script:dl2 'Yes' 'Mail - Sales' 'Sales lists' $null
        ) | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -BicepOutput -Confirm:$false

        $bicep = Get-Content (Get-ChildItem $TestDrive -Filter '*.bicepparam').FullName -Raw
        $bicep | Should -Match 'param distributionListMapping = \{'
        $bicep | Should -Match "'dl1@contoso.com'"
        $bicep | Should -Match ([regex]::Escape("'o\'brien@contoso.com'"))
    }

    It 'links to an existing package with the same name instead of creating a duplicate' {
        $existingId = [guid]::NewGuid().ToString()
        $script:existingPackages = @([pscustomobject]@{ id = $existingId; displayName = 'Mail - Sales'; description = 'Sales lists'; catalog = $script:catalog })
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        $result = Get-LatestResult
        $result[0].Status | Should -Be 'Linked'
        $result[0].AccessPackageId | Should -Be $existingId
        $script:writes.Count | Should -Be 0
    }

    It 'is Unchanged when run again with the id already filled in' {
        $existingId = [guid]::NewGuid().ToString()
        $script:existingPackages = @([pscustomobject]@{ id = $existingId; displayName = 'Mail - Sales'; description = 'Sales lists'; catalog = $script:catalog })
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $existingId | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        (Get-LatestResult)[0].Status | Should -Be 'Unchanged'
        $script:writes.Count | Should -Be 0
    }

    It 'updates the description when it differs from Entra' {
        $existingId = [guid]::NewGuid().ToString()
        $script:existingPackages = @([pscustomobject]@{ id = $existingId; displayName = 'Mail - Sales'; description = 'old text'; catalog = $script:catalog })
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $existingId | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        (Get-LatestResult)[0].Status | Should -Be 'Updated'
        $script:writes[0].method | Should -Be 'PATCH'
    }

    It 'flags the same name with different descriptions as Invalid and changes nothing' {
        @(
            New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null
            New-Row $script:dl2 'Yes' 'Mail - Sales' 'Something else' $null
        ) | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        (Get-LatestResult).Status | Should -Be @('Invalid', 'Invalid')
        $script:writes.Count | Should -Be 0
        $err[0].CategoryInfo.Category | Should -Be 'InvalidData'
        "$($err[0])" | Should -Match '2 row\(s\) failed validation'
    }

    It 'still writes the results file before the validation error, also with -ErrorAction Stop' {
        New-Row '../../users' 'Yes' 'Hack' 'x' $null | Export-Excel "$TestDrive/in.xlsx"

        { Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false -ErrorAction Stop } |
            Should -Throw '*failed validation*'

        (Get-LatestResult)[0].Status | Should -Be 'Invalid'
    }

    It 'rejects an ObjectId that is not a GUID' {
        New-Row '../../users' 'Yes' 'Hack' 'x' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false -ErrorAction SilentlyContinue

        $result = Get-LatestResult
        $result[0].Status | Should -Be 'Invalid'
        $result[0].StatusMessage | Should -Match 'not a valid GUID'
    }

    It 'flags a list that does not exist in Entra' {
        New-Row ([guid]::NewGuid().ToString()) 'Yes' 'Mail - Gone' 'x' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false -ErrorAction SilentlyContinue

        (Get-LatestResult)[0].StatusMessage | Should -Match 'not found in Entra'
    }

    It '-OutputPath saves the results there without opening the folder dialog' {
        New-Item -Path "$TestDrive/reports" -ItemType Directory | Out-Null
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -OutputPath "$TestDrive/reports" -BicepOutput -Confirm:$false

        Should -Invoke Select-FolderPath -Times 0
        @(Get-ChildItem "$TestDrive/reports" -Filter 'AccessPackages-*.xlsx').Count | Should -Be 1
        @(Get-ChildItem "$TestDrive/reports" -Filter '*.bicepparam').Count | Should -Be 1
    }

    It 'stops with an error before anything else when -OutputPath does not exist' {
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -OutputPath "$TestDrive/does-not-exist" -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
        Should -Invoke Confirm-GraphConnection -Times 0
        $script:writes.Count | Should -Be 0
    }

    It 'asks for the folder first, and does nothing when the dialog is cancelled' {
        Mock Select-FolderPath { $null }
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        Should -Invoke Confirm-GraphConnection -Times 0
        $script:writes.Count | Should -Be 0
    }

    It 'returns the result rows, without the internal row number' {
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        $rows = @(Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false)

        $rows.Count | Should -Be 1
        $rows[0].Status | Should -Be 'Created'
        $rows[0].AccessPackageId | Should -Not -BeNullOrEmpty
        $rows[0].PSObject.Properties.Name | Should -Not -Contain '_ExcelRow'
        $rows[0].PSObject.TypeNames[0] | Should -Be 'SiSGovernance.DistributionListRow'
    }

    It '-Confirm:$false runs without asking' {
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -Confirm:$false

        (Get-LatestResult)[0].Status | Should -Be 'Created'
        $script:writes.Count | Should -Be 1
    }

    It 'writes an error and changes nothing when the run is over -MaxPackages' {
        @(
            New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null
            New-Row $script:dl2 'Yes' 'Mail - HR' 'HR lists' $null
        ) | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -MaxPackages 1 -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

        $err[0].CategoryInfo.Category | Should -Be 'LimitsExceeded'
        (Get-LatestResult).Status | Should -Be @('NotProcessed', 'NotProcessed')
        $script:writes.Count | Should -Be 0
    }

    It '-WhatIf writes a Preview file and changes nothing' {
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogName 'Test Catalog' -WhatIf

        (Get-LatestResult -Prefix 'Preview')[0].Status | Should -Be 'Preview - Create'
        $script:writes.Count | Should -Be 0
    }

    It 'with -CatalogId, passes it on as a lowercase GUID string' {
        New-Row $script:dl1 'Yes' 'Mail - Sales' 'Sales lists' $null | Export-Excel "$TestDrive/in.xlsx"

        Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogId $script:catalog.id.ToUpperInvariant() -WhatIf

        Should -Invoke Resolve-AccessPackageCatalog -Times 1 -Exactly -ParameterFilter { $CatalogId -ceq $script:catalog.id }
    }

    It 'rejects a CatalogId that is not a GUID' {
        { Sync-SiSAccessPackage -ExcelPath "$TestDrive/in.xlsx" -CatalogId 'bad' -ErrorAction Stop } | Should -Throw
    }
}


Describe 'New-SiSAccessPackage' {
    BeforeAll {
        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Resolve-AccessPackageCatalog { $null }
    }

    It 'with -CatalogName, looks the catalog up by name only' {
        New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogName 'Identity - Employee'

        Should -Invoke Resolve-AccessPackageCatalog -ParameterFilter { -not $CatalogId -and $CatalogName -eq 'Identity - Employee' } -Times 1 -Exactly
    }

    It 'with -CatalogId, passes it on as a lowercase GUID string' {
        $id = [guid]::NewGuid().ToString()

        New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogId $id.ToUpperInvariant()

        Should -Invoke Resolve-AccessPackageCatalog -ParameterFilter { $CatalogId -ceq $id } -Times 1 -Exactly
    }

    It 'rejects a CatalogId that is not a GUID' {
        { New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogId 'bad' -ErrorAction Stop } | Should -Throw
    }

    Context 'with a catalog' {
        BeforeAll {
            Mock Resolve-AccessPackageCatalog { [pscustomobject]@{ id = 'cat-1'; displayName = 'Identity - Employee' } }
        }

        BeforeEach {
            $script:existingNew = @()
            Mock Get-GraphPagedResult { $script:existingNew }
            Mock Invoke-MgGraphRequest { @{ id = 'ap-1'; displayName = 'App - Test' } }
        }

        It 'writes an error and creates nothing when the name already exists in the catalog' {
            $script:existingNew = @([pscustomobject]@{ id = 'ap-old'; catalog = [pscustomobject]@{ id = 'cat-1' } })

            New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogName 'Identity - Employee' -Confirm:$false -ErrorVariable err -ErrorAction SilentlyContinue

            $err[0].CategoryInfo.Category | Should -Be 'ResourceExists'
            Should -Invoke Invoke-MgGraphRequest -Times 0
        }

        It '-WhatIf creates nothing' {
            New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogName 'Identity - Employee' -WhatIf

            Should -Invoke Invoke-MgGraphRequest -Times 0
        }

        It '-Confirm:$false creates it without asking and returns the new package' {
            $ap = New-SiSAccessPackage -DisplayName 'App - Test' -Description 'Test' -CatalogName 'Identity - Employee' -Confirm:$false

            Should -Invoke Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } -Times 1 -Exactly
            $ap.Id | Should -Be 'ap-1'
            $ap.CatalogName | Should -Be 'Identity - Employee'
            $ap.PSObject.TypeNames[0] | Should -Be 'SiSGovernance.AccessPackage'
        }
    }
}


Describe 'Get-SiSGraphUser' {
    It 'returns no users, and warns, when nobody matches the filter' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('User.Read.All') } }
        Mock Invoke-MgGraphRequest { [pscustomobject]@{ '@odata.context' = 'x'; value = @() } }

        $users = Get-SiSGraphUser -Filter "department eq 'Nobody'" -WarningVariable warnings -WarningAction SilentlyContinue

        @($users).Count | Should -Be 0
        "$($warnings[0])" | Should -Match 'No users matched'
    }

    It 'queries nothing when there is no Graph connection' {
        Mock Get-MgContext { $null }
        Mock Get-GraphPagedResult { throw 'must not be called' }

        $users = Get-SiSGraphUser -Filter "userType eq 'Member'" -ErrorVariable err -ErrorAction SilentlyContinue

        @($users).Count | Should -Be 0
        $err.Count | Should -Be 1
        Should -Invoke Get-GraphPagedResult -Times 0
    }

    It 'returns the users matching the filter' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('User.Read.All') } }
        Mock Get-GraphPagedResult {
            [pscustomobject]@{ id = '1'; displayName = 'Anna'; userPrincipalName = 'anna@contoso.com' }
            [pscustomobject]@{ id = '2'; displayName = 'Erik'; userPrincipalName = 'erik@contoso.com' }
        }

        $users = Get-SiSGraphUser -Filter "department eq 'Sales'"

        $users.userPrincipalName | Should -Be @('anna@contoso.com', 'erik@contoso.com')
    }

    It 'URL-encodes the filter, so & and # cannot break the request' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('User.Read.All') } }
        Mock Get-GraphPagedResult { [pscustomobject]@{ id = '1'; userPrincipalName = 'anna@contoso.com' } }

        Get-SiSGraphUser -Filter "department eq 'R&D #1'" | Out-Null

        Should -Invoke Get-GraphPagedResult -ParameterFilter { $Uri -like '*R%26D%20%231*' -and $Uri -notlike '*R&D*' } -Times 1 -Exactly
    }

    It 'sends the users one at a time down the pipeline, not as one array' {
        Mock Get-MgContext { [pscustomobject]@{ Account = 'test'; AuthType = 'Delegated'; Scopes = @('User.Read.All') } }
        Mock Get-GraphPagedResult {
            [pscustomobject]@{ id = '1'; userPrincipalName = 'anna@contoso.com' }
            [pscustomobject]@{ id = '2'; userPrincipalName = 'erik@contoso.com' }
        }

        $count = 0
        Get-SiSGraphUser -Filter "department eq 'Sales'" | ForEach-Object { $count++ }

        $count | Should -Be 2
    }
}


Describe 'Export-SafeExcelTable' {
    It 'writes text that starts with = as text - never as a formula' {
        $path = Join-Path $TestDrive 'safe.xlsx'
        $rows = @([pscustomobject]@{ DisplayName = '=HYPERLINK("http://evil","x")'; Mail = 'dl@contoso.com'; Count = 3 })

        $excel = Export-SafeExcelTable -InputObject $rows -Path $path -WorksheetName 'Sheet' -TableName 'Table'
        Close-ExcelPackage $excel

        $package = Open-ExcelPackage -Path $path
        try {
            $cell = $package.Workbook.Worksheets['Sheet'].Cells[2, 1]
            $cell.Formula | Should -BeNullOrEmpty
            $cell.Value | Should -Be '=HYPERLINK("http://evil","x")'
        }
        finally { Close-ExcelPackage $package -NoSave }
        (Import-Excel $path).DisplayName | Should -Be '=HYPERLINK("http://evil","x")'
    }

    It 'never turns text into a clickable link' {
        $path = Join-Path $TestDrive 'links.xlsx'

        $excel = Export-SafeExcelTable -InputObject @([pscustomobject]@{ DisplayName = 'https://evil.example' }) -Path $path -WorksheetName 'Sheet' -TableName 'Table'
        Close-ExcelPackage $excel

        $package = Open-ExcelPackage -Path $path
        try { $package.Workbook.Worksheets['Sheet'].Cells[2, 1].Hyperlink | Should -BeNullOrEmpty }
        finally { Close-ExcelPackage $package -NoSave }
    }
}


Describe 'Export-SiSDistributionList' {
    BeforeAll {
        $script:exportDl = [guid]::NewGuid().ToString()
        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Select-FolderPath { $TestDrive }
        Mock Get-GraphPagedResult {
            [pscustomobject]@{ id = $script:exportDl; displayName = 'DL1'; mail = 'dl1@contoso.com'; onPremisesSyncEnabled = $null }
        }
        Mock Invoke-MgGraphRequest {
            New-BatchResponse -Body $Body -PerRequest {
                param($req)
                if ($req.url -match '/members') { @{ status = 200; body = @{ '@odata.count' = 3; value = @() } } }
                else { @{ status = 200; body = @{ value = @(@{ userPrincipalName = 'owner@contoso.com' }) } } }
            }
        }
    }

    BeforeEach {
        Get-ChildItem $TestDrive | Remove-Item -Recurse -Force
    }

    It 'exports the lists with member count and owners, and an empty Include column' {
        Export-SiSDistributionList

        $file = Get-ChildItem $TestDrive -Filter 'DistributionLists-*.xlsx'
        @($file).Count | Should -Be 1
        $row = @(Import-Excel $file.FullName)[0]
        $row.ObjectId | Should -Be $script:exportDl
        $row.PrimarySmtpAddress | Should -Be 'dl1@contoso.com'
        $row.MemberCount | Should -Be 3
        $row.Owners | Should -Be 'owner@contoso.com'
        $row.Include | Should -BeNullOrEmpty
    }

    It 'returns the same rows as in the file' {
        $rows = @(Export-SiSDistributionList)

        $rows.Count | Should -Be 1
        $rows[0].ObjectId | Should -Be $script:exportDl
        $rows[0].PSObject.TypeNames[0] | Should -Be 'SiSGovernance.DistributionListRow'
    }

    It '-OutputPath saves the file there without opening the folder dialog' {
        New-Item -Path "$TestDrive/reports" -ItemType Directory | Out-Null

        Export-SiSDistributionList -OutputPath "$TestDrive/reports"

        Should -Invoke Select-FolderPath -Times 0
        @(Get-ChildItem "$TestDrive/reports" -Filter 'DistributionLists-*.xlsx').Count | Should -Be 1
    }

    It 'asks for the folder first, and does nothing when the dialog is cancelled' {
        Mock Select-FolderPath { $null }

        Export-SiSDistributionList

        Should -Invoke Confirm-GraphConnection -Times 0
        Should -Invoke Get-GraphPagedResult -Times 0
    }
}


Describe 'Add-SiSAccessPackageResource / Remove-SiSAccessPackageResource' {
    BeforeAll {
        $script:apId = [guid]::NewGuid().ToString()
        $script:gid = [guid]::NewGuid().ToString()

        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Get-CatalogResource {
            [pscustomobject]@{
                Resource       = [pscustomobject]@{
                    id = 'res-1'; originId = $script:gid; displayName = 'LIC-M365-E5'
                    scopes = @([pscustomobject]@{ id = 'scope-1'; originId = $script:gid; isRootScope = $true })
                }
                Roles          = @(
                    [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000000'; originId = "Member_$($script:gid)"; displayName = 'Member' }
                    [pscustomobject]@{ id = '00000000-0000-0000-0000-000000000000'; originId = "Owner_$($script:gid)"; displayName = 'Owner' }
                )
                AddedToCatalog = $false
                Error          = $null
            }
        }
    }

    BeforeEach {
        $script:existingScopes = @()
        $script:requests = [System.Collections.Generic.List[object]]::new()
        Mock Get-AccessPackageResourceState {
            [pscustomobject]@{
                Package            = @{ displayName = 'License - Baseline 5' }
                CatalogId          = 'cat-1'
                CatalogName        = 'Identity - Employee'
                ResourceRoleScopes = $script:existingScopes
                Error              = $null
            }
        }
        Mock Invoke-MgGraphRequest {
            $script:requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
        }
    }

    It 'adds the Member role of a group, without a role id and with the root scope' {
        $r = Add-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -Confirm:$false

        $r.Status | Should -Be 'Added'
        $r.PSObject.TypeNames[0] | Should -Be 'SiSGovernance.ResourceChangeResult'
        $body = $script:requests[0].Body | ConvertFrom-Json
        $body.role.originId | Should -Be "Member_$($script:gid)"
        $body.role.PSObject.Properties.Name | Should -Not -Contain 'id'
        $body.scope.isRootScope | Should -BeTrue
    }

    It 'takes the access package from the pipeline (e.g. New-SiSAccessPackage output)' {
        $r = [pscustomobject]@{ Id = $script:apId; DisplayName = 'License - Baseline 5' } |
            Add-SiSAccessPackageResource -GroupId $script:gid -Confirm:$false

        $r.Status | Should -Be 'Added'
    }

    It 'is AlreadyAdded when the package already has the role' {
        $script:existingScopes = @([pscustomobject]@{
                id    = 'rrs-1'
                role  = [pscustomobject]@{ originId = "Member_$($script:gid)"; displayName = 'Member' }
                scope = [pscustomobject]@{ originId = $script:gid }
            })

        $r = Add-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -Confirm:$false

        $r.Status | Should -Be 'AlreadyAdded'
        $script:requests.Count | Should -Be 0
    }

    It '-WhatIf changes nothing' {
        $r = Add-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -WhatIf

        $r.Status | Should -Be 'Preview - Add'
        $script:requests.Count | Should -Be 0
    }

    It '-WhatIf on Remove changes nothing' {
        $script:existingScopes = @([pscustomobject]@{
                id    = 'rrs-1'
                role  = [pscustomobject]@{ originId = "Member_$($script:gid)"; displayName = 'Member' }
                scope = [pscustomobject]@{ originId = $script:gid }
            })

        $r = Remove-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -WhatIf

        $r.Status | Should -Be 'Preview - Remove'
        $script:requests.Count | Should -Be 0
    }

    It 'removes the role when the package has it' {
        $script:existingScopes = @([pscustomobject]@{
                id    = 'rrs-1'
                role  = [pscustomobject]@{ originId = "Member_$($script:gid)"; displayName = 'Member'; resource = [pscustomobject]@{ displayName = 'LIC-M365-E5' } }
                scope = [pscustomobject]@{ originId = $script:gid }
            })

        $r = Remove-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -Confirm:$false

        $r.Status | Should -Be 'Removed'
        $script:requests[0].Method | Should -Be 'DELETE'
        $script:requests[0].Uri | Should -Match 'resourceRoleScopes/rrs-1$'
    }

    It 'is NotOnPackage when there is nothing to remove' {
        $r = Remove-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid -Confirm:$false

        $r.Status | Should -Be 'NotOnPackage'
        $script:requests.Count | Should -Be 0
    }

    It 'accepts GUID strings in any casing from the pipeline and uses them in lowercase' {
        $upper = $script:apId.ToUpperInvariant()

        [pscustomobject]@{ Id = $upper } | Add-SiSAccessPackageResource -GroupId $script:gid -WhatIf | Out-Null

        Should -Invoke Get-AccessPackageResourceState -ParameterFilter { $AccessPackageId -ceq $script:apId } -Times 1 -Exactly
    }

    It 'rejects an access package id that is not a GUID' {
        { Add-SiSAccessPackageResource -AccessPackageId 'not-a-guid' -GroupId $script:gid } | Should -Throw
    }

    It 'rejects a GroupId or ApplicationId that is not a GUID' {
        { Add-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId 'not-a-guid' } | Should -Throw
        { Remove-SiSAccessPackageResource -AccessPackageId $script:apId -ApplicationId '../../users' -RoleName 'User' } | Should -Throw
    }

    It 'passes the group id on as a lowercase GUID string' {
        Add-SiSAccessPackageResource -AccessPackageId $script:apId -GroupId $script:gid.ToUpperInvariant() -WhatIf | Out-Null

        Should -Invoke Get-CatalogResource -ParameterFilter { $Spec.OriginId -ceq $script:gid } -Times 1 -Exactly
    }
}


Describe 'Get-SiSAccessPackageResourceRole' {
    BeforeAll {
        $script:roleGid = [guid]::NewGuid().ToString()
        $script:roleCatalog = [pscustomobject]@{ id = [guid]::NewGuid().ToString(); displayName = 'Identity - Employee' }

        Mock Confirm-GraphConnection { [pscustomobject]@{ Account = 'test' } }
        Mock Resolve-AccessPackageCatalog { $script:roleCatalog }
    }

    BeforeEach {
        Mock Get-CatalogResource {
            [pscustomobject]@{
                Resource       = [pscustomobject]@{ id = 'res-1'; originId = $script:roleGid; displayName = 'LIC-M365-E5' }
                Roles          = @(
                    [pscustomobject]@{ originId = "Owner_$($script:roleGid)"; displayName = 'Owner'; description = '' }
                    [pscustomobject]@{ originId = "Member_$($script:roleGid)"; displayName = 'Member'; description = '' }
                )
                AddedToCatalog = $false
                Error          = $null
            }
        }
    }

    It 'lists the roles of a group, sorted by name' {
        $roles = Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee'

        $roles.RoleName | Should -Be @('Member', 'Owner')
        $roles[0].PSObject.TypeNames[0] | Should -Be 'SiSGovernance.ResourceRole'
        $roles[0].Resource | Should -Be 'LIC-M365-E5'
        $roles[0].ResourceType | Should -Be 'Group'
    }

    It 'passes the group id and catalog id on as lowercase GUID strings' {
        Get-SiSAccessPackageResourceRole -GroupId $script:roleGid.ToUpperInvariant() -CatalogId $script:roleCatalog.id.ToUpperInvariant() | Out-Null

        Should -Invoke Resolve-AccessPackageCatalog -ParameterFilter { $CatalogId -ceq $script:roleCatalog.id } -Times 1 -Exactly
        Should -Invoke Get-CatalogResource -ParameterFilter { $Spec.OriginId -ceq $script:roleGid } -Times 1 -Exactly
    }

    It 'needs exactly one of -CatalogName or -CatalogId' {
        Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -ErrorVariable err1 -ErrorAction SilentlyContinue | Out-Null
        Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' -CatalogId $script:roleCatalog.id -ErrorVariable err2 -ErrorAction SilentlyContinue | Out-Null

        $err1[0].CategoryInfo.Category | Should -Be 'InvalidArgument'
        $err2[0].CategoryInfo.Category | Should -Be 'InvalidArgument'
        Should -Invoke Confirm-GraphConnection -Times 0
    }

    It 'only reads, and does not add the resource to the catalog, without -AddToCatalog' {
        Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' | Out-Null

        Should -Invoke Confirm-GraphConnection -ParameterFilter { $Scopes -eq 'EntitlementManagement.Read.All' } -Times 1 -Exactly
        Should -Invoke Get-CatalogResource -ParameterFilter { -not $AddIfMissing } -Times 1 -Exactly
    }

    Context 'resource not in the catalog yet' {
        BeforeEach {
            Mock Get-CatalogResource { [pscustomobject]@{ Resource = $null; Roles = @(); AddedToCatalog = $false; Error = 'Resource is not in the catalog' } }
            Mock Get-CatalogResource -ParameterFilter { $AddIfMissing } {
                [pscustomobject]@{
                    Resource       = [pscustomobject]@{ id = 'res-1'; originId = $script:roleGid; displayName = 'LIC-M365-E5' }
                    Roles          = @([pscustomobject]@{ originId = "Member_$($script:roleGid)"; displayName = 'Member'; description = '' })
                    AddedToCatalog = $true
                    Error          = $null
                }
            }
        }

        It 'writes an error, with a hint about -AddToCatalog, and returns nothing' {
            $roles = Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' -ErrorVariable err -ErrorAction SilentlyContinue

            $roles | Should -BeNullOrEmpty
            $err[0].CategoryInfo.Category | Should -Be 'ObjectNotFound'
            "$($err[0])" | Should -Match '-AddToCatalog'
            Should -Invoke Get-CatalogResource -ParameterFilter { $AddIfMissing } -Times 0
        }

        It 'with -AddToCatalog, asks for write access, adds the resource and lists its roles - without a prompt' {
            $roles = Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' -AddToCatalog

            Should -Invoke Confirm-GraphConnection -ParameterFilter { $Scopes -eq 'EntitlementManagement.ReadWrite.All' } -Times 1 -Exactly
            Should -Invoke Get-CatalogResource -ParameterFilter { $AddIfMissing } -Times 1 -Exactly
            $roles.RoleName | Should -Be 'Member'
        }

        It '-AddToCatalog -WhatIf adds nothing' {
            Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' -AddToCatalog -WhatIf | Out-Null

            Should -Invoke Get-CatalogResource -ParameterFilter { $AddIfMissing } -Times 0
        }
    }

    It 'with -AddToCatalog, adds nothing when the resource is already in the catalog' {
        Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogName 'Identity - Employee' -AddToCatalog | Out-Null

        Should -Invoke Get-CatalogResource -ParameterFilter { $AddIfMissing } -Times 0
    }

    It 'rejects a GroupId, ApplicationId or CatalogId that is not a GUID' {
        { Get-SiSAccessPackageResourceRole -GroupId 'not-a-guid' -CatalogName 'Identity - Employee' } | Should -Throw
        { Get-SiSAccessPackageResourceRole -ApplicationId '../../users' -CatalogName 'Identity - Employee' } | Should -Throw
        { Get-SiSAccessPackageResourceRole -GroupId $script:roleGid -CatalogId 'bad' } | Should -Throw
    }
}

}   # InModuleScope


Describe 'Module SiSGovernance' {
    BeforeAll {
        $manifestPath = Join-Path $PSScriptRoot '../SiSGovernance/SiSGovernance.psd1'
        $expectedFunctions = @(
            'Add-SiSAccessPackageAssignment'
            'Remove-SiSAccessPackageAssignment'
            'New-SiSAccessPackage'
            'Add-SiSAccessPackageResource'
            'Remove-SiSAccessPackageResource'
            'Get-SiSAccessPackageResourceRole'
            'Export-SiSDistributionList'
            'Sync-SiSAccessPackage'
            'Get-SiSGraphUser'
        ) | Sort-Object
    }

    It 'every function that changes something supports -WhatIf and -Confirm, and asks by default' {
        foreach ($name in 'Add-SiSAccessPackageAssignment', 'Remove-SiSAccessPackageAssignment', 'New-SiSAccessPackage',
            'Add-SiSAccessPackageResource', 'Remove-SiSAccessPackageResource', 'Sync-SiSAccessPackage') {
            $meta = [System.Management.Automation.CommandMetadata]::new((Get-Command $name))
            $meta.SupportsShouldProcess | Should -BeTrue -Because $name
            $meta.ConfirmImpact | Should -Be 'High' -Because $name
            (Get-Command $name).Parameters.ContainsKey('PreviewOnly') | Should -BeFalse -Because $name
        }
    }

    It 'declares what every public function that returns objects outputs' {
        $expected = @{
            'Add-SiSAccessPackageAssignment'    = 'SiSGovernance.AssignmentResult'
            'Remove-SiSAccessPackageAssignment' = 'SiSGovernance.AssignmentResult'
            'New-SiSAccessPackage'              = 'SiSGovernance.AccessPackage'
            'Add-SiSAccessPackageResource'      = 'SiSGovernance.ResourceChangeResult'
            'Remove-SiSAccessPackageResource'   = 'SiSGovernance.ResourceChangeResult'
            'Get-SiSAccessPackageResourceRole'  = 'SiSGovernance.ResourceRole'
            'Get-SiSGraphUser'                  = 'System.Management.Automation.PSObject'
        }
        foreach ($name in $expected.Keys) {
            (Get-Command $name).OutputType.Name | Should -Contain $expected[$name] -Because $name
        }
    }

    It 'never prompts with Read-Host - confirmation goes through ShouldProcess' {
        foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot '../SiSGovernance') -Filter '*.ps*1' -Recurse) {
            Get-Content -Path $file.FullName -Raw | Should -Not -Match 'Read-Host' -Because $file.Name
        }
    }

    It 'has help, at the top of the function, for every function - private helpers too' {
        $files = Get-ChildItem -Path (Join-Path $PSScriptRoot '../SiSGovernance/Public'), (Join-Path $PSScriptRoot '../SiSGovernance/Private') -Filter '*.ps1'
        $functions = foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $found = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
            # One function per file, named like the file
            $found.Count | Should -Be 1 -Because $file.Name
            $found[0].Name | Should -Be $file.BaseName
            $found[0]
        }

        $functions.Count | Should -BeGreaterThan 20
        foreach ($f in $functions) {
            $f.GetHelpContent().Synopsis | Should -Not -BeNullOrEmpty -Because $f.Name
            $f.Body.Extent.Text.TrimStart('{').TrimStart() | Should -BeLike '<#*' -Because "$($f.Name) should start with its help"
        }
    }

    It 'has a valid manifest' {
        { Test-ModuleManifest -Path $manifestPath -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the public SiS functions - no helpers' {
        $module = Import-Module $manifestPath -Force -PassThru
        try {
            @($module.ExportedFunctions.Keys | Sort-Object) | Should -Be $expectedFunctions
            $module.ExportedFunctions.Keys | Should -Not -Contain 'Invoke-GraphBatch'
            $module.ExportedVariables.Count | Should -Be 0
        }
        finally {
            Remove-Module $module -Force
        }
    }

    It 'has help (a synopsis) for every public function' {
        $module = Import-Module $manifestPath -Force -PassThru
        try {
            foreach ($name in $expectedFunctions) {
                # Without comment-based help, PowerShell falls back to the syntax line as synopsis
                (Get-Help $name).Synopsis.Trim() | Should -Not -BeLike "$name *" -Because "$name needs comment-based help"
            }
        }
        finally {
            Remove-Module $module -Force
        }
    }
}
