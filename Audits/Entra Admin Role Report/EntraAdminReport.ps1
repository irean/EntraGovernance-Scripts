[CmdletBinding()]
param()
#helper method to manager fething paged results
function igall {
    [CmdletBinding()]
    param (
        [string]$Uri
    )
    $nextUri = $uri
    do {
        $result = $null
        $time = Measure-Command { 
            $result = Invoke-MgGraphRequest -Method GET -Uri $nextUri
        }
        Write-Debug "callto $nextURI took $time"
        $nextUri = $result.'@odata.nextLink'
        if ($result -and $result.ContainsKey('value')) {
            $result.value
        }
        else {
            $result
        }
    } while ($nextUri)
}



$cache = @{}
function Get-User {
    param (
        [string]$Id
    )

    
    if (-not $cache[$Id]) {

        $user = igall "https://graph.microsoft.com/v1.0/users/$($id)?`$select=Displayname%2CUserprincipalname%2CcompanyName%2CaccountEnabled%2CCreatedDatetime%2CLastPasswordChangeDateTime%2csignInActivity%2clastNonInteractiveSignInDateTime%2clastSignInDateTime%2CassignedLicenses%2CassignedPlans"

        $temp = [pscustomobject]$user
        $result = $temp
        | Add-Member -NotePropertyName lastSignInDateTime -NotePropertyValue $user.signInActivity.lastSignInDateTime -Force -PassThru
        | Add-Member -NotePropertyName lastNonInteractiveSignInDateTime -NotePropertyValue $user.signInActivity.lastNonInteractiveSignInDateTime -Force -PassThru
        | Add-Member -NotePropertyName hasStrongMFA -NotePropertyValue $false -Force -PassThru
        | Add-Member -NotePropertyName 'Roles' -NotePropertyValue @() -PassThru -Force
        | Add-Member -NotePropertyName "EligibleRoles" -NotePropertyValue @() -PassThru -Force
        | Add-Member -NotePropertyName 'AzureRoles' -NotePropertyValue @() -PassThru -Force
        | Add-Member -NotePropertyName 'AdminRiskScore' -NotePropertyValue 0 -PassThru -Force
        | Add-Member -NotePropertyName 'AdminRiskLevel' -NotePropertyValue 0 -PassThru -Force
        | Add-Member -NotePropertyName 'UserType' -NotePropertyValue 'User' -PassThru -Force

        Start-Sleep -Milliseconds 250 

        $auth = Invoke-MgGraphRequest -Method GET  -Uri "https://graph.microsoft.com/beta/users/$Id/authentication/methods"
        $count = $auth.value.'@odata.type' | Where-Object {
            $_ -notmatch 'passwordAuthenticationMethod|phoneAuthenticationMethod'
        } | measure-object 

        $result | Add-Member -NotePropertyName StrongAuthCount -NotePropertyValue $count.count -Force

        foreach ($method in $auth.value) {

            switch ($method.'@odata.type') {

                '#microsoft.graph.passwordAuthenticationMethod' {
                    $result | Add-Member -NotePropertyName AuthPassword -NotePropertyValue $method.createdDateTime -Force

                }

                '#microsoft.graph.phoneAuthenticationMethod' {
                    $result | Add-Member -NotePropertyName AuthPhone -NotePropertyValue $method.phoneNumber -Force

                    
                }

                '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' {
                    $result | Add-Member -NotePropertyName AuthMicrosoftAuthenticator -NotePropertyValue $method.displayName -Force
                    $result.hasStrongMFA = $true
                }

                '#microsoft.graph.passwordlessMicrosoftAuthenticatorAuthenticationMethod' {
                    $result | Add-Member -NotePropertyName AuthPasswordless -NotePropertyValue $method.displayName -Force
                    $result.hasStrongMFA = $true
                }

                '#microsoft.graph.fido2AuthenticationMethod' {

                    $result | Add-Member -NotePropertyName AuthFido2 -NotePropertyValue $method.displayName -Force
                    $result.hasStrongMFA = $true

                }
            }
        }
        if ($user.assignedLicenses.Count -gt 0) {
            $result | Add-Member -NotePropertyName IsLicensed -NotePropertyValue $true -Force
        }
        else {
            $result | Add-Member -NotePropertyName IsLicensed -NotePropertyValue $false -Force
        }


        $enabledProductivityPlans = $user.assignedPlans | Where-Object {
            $_.capabilityStatus -eq "Enabled" -and
            $_.service -match "EXCHANGE|SHAREPOINT|TEAMS|FLOW|POWERAPPS"
        }

        if ($enabledProductivityPlans) {
            $result | Add-Member -NotePropertyName ProductivityServicesEnabled -NotePropertyValue $true -Force
        }
        else {
            $result | Add-Member -NotePropertyName ProductivityServicesEnabled -NotePropertyValue $false -Force
        }

        $productivityServices = $enabledProductivityPlans.service |
        Sort-Object -Unique

        $result | Add-Member -NotePropertyName ProductivityServices `
            -NotePropertyValue ($productivityServices -join ", ") `
            -Force

 

        $cache[$Id] = $result
    }

    return $cache[$Id]
}

function Get-ServicePrincipal {
    param (
        [string]$Id
    )
    # todo hämta service principal
    
    if (-not $cache[$Id]) {
        $user = igall "https://graph.microsoft.com/v1.0/servicePrincipals/$($id)"
        if (-not $user) {
            $cache[$id] = $null
            return $null
        }
        $temp = [pscustomobject]$user
        $result = $temp
        | Add-Member -NotePropertyName lastSignInDateTime -NotePropertyValue '' -Force -PassThru
        | Add-Member -NotePropertyName lastNonInteractiveSignInDateTime -NotePropertyValue '' -Force -PassThru
        | Add-Member -NotePropertyName hasStrongMFA -NotePropertyValue $false -Force -PassThru
        | Add-Member -NotePropertyName 'Roles' -NotePropertyValue @() -PassThru -Force
        | Add-Member -NotePropertyName "EligibleRoles" -NotePropertyValue $() -PassThru -Force
        | Add-Member -NotePropertyName 'AzureRoles' -NotePropertyValue @() -PassThru -Force
        | Add-Member -NotePropertyName 'AdminRiskScore' -NotePropertyValue 0 -PassThru -Force
        | Add-Member -NotePropertyName 'AdminRiskLevel' -NotePropertyValue 0 -PassThru -Force
        | Add-Member -NotePropertyName 'UserType' -NotePropertyValue 'ServicePrincipal' -PassThru -Force
        $cache[$Id] = $result
    }

    return $cache[$Id]
}
# ROLE RISK
$RoleRiskTable = @{
    "Global Administrator"          = 10
    "Privileged Role Administrator" = 9
    "Security Administrator"        = 8
    "User Administrator"            = 7
    "Groups Administrator"          = 6
}

function Get-AdminRiskScore {
    param(
        $User
    )

    $score = 0

    # Disabled accounts = no risk
    if ($User.accountEnabled -eq $false) {
        return 0
    }

    $roleScores = @()

    foreach ($role in $User.Roles) {
        if ($RoleRiskTable.ContainsKey($role)) {
            $roleScores += $RoleRiskTable[$role]
        }
        else {
            $roleScores += 3
        }
    }
    foreach ($role in $User.EligibleRoles) {
        if ($RoleRiskTable.ContainsKey($role)) {
            $roleScores += $RoleRiskTable[$role]
        }
        else {
            $roleScores += 3
        }
    }
    foreach ($role in $user.AzureRoles) {
        if ($assignment.RoleDefinitionName -match "Owner") { $roleScores += 10 }
        elseif ($assignment.RoleDefinitionName -match "User Access Administrator") { $roleScores += 8 }
        elseif ($assignment.RoleDefinitionName -match "Contributor") { $roleScores += 6 }
        elseif ($assignment.RoleDefinitionName -match "Reader") { $roleScores += 1 }
    }

    if ($roleScores.Count -gt 0) {

        # Highest privilege drives base risk
        $maxRole = ($roleScores | Measure-Object -Maximum).Maximum
        $score += $maxRole

        # Extra roles add smaller incremental risk
        $extraRoles = $roleScores.Count - 1
        if ($extraRoles -gt 0) {
            $score += ($extraRoles * 2)
        }

        # Optional: many roles = extra concern
        if ($roleScores.Count -ge 3) {
            $score += 2
        }
    }
    return $score
}
function Get-AdminRiskLevel {

    param($Score)

    if ($Score -ge 15) { return "Critical" }
    elseif ($Score -ge 10) { return "High" }
    elseif ($Score -ge 5) { return "Medium" }
    else { return "Low" }
}



function test-module {
    [CmdletBinding()]
    param(
        [String]$Name
  
    )
    Write-Host "Checking module $name..." -ForegroundColor Cyan
    if (-not (Get-Module $Name)) {
        Write-Host "Module $Name not imported, trying to import..." -ForegroundColor Yellow
        try {
            if ($Name -eq 'Microsoft.Graph') {
                Write-Host "Microsoft.Graph module import takes a while..." -ForegroundColor Yellow
                Import-Module $Name  -ErrorAction Stop
            }
            elseif ($Name -eq 'Az') {
                Write-Host "Module Az is being imported. This might take a while..." -ForegroundColor Yellow
            }
            else {
                Import-Module $Name  -ErrorAction Stop
            }
        
        }
        catch {
            Write-Host "Module $Name not found, trying to install..." -ForegroundColor Yellow
            Install-Module $Name -Scope CurrentUser -AllowClobber -Force -AcceptLicense -SkipPublisherCheck
            Write-Host "Importing module $Name..." -ForegroundColor Yellow
            Import-Module $Name -ErrorAction Stop
        }
    } 
    else {
        Write-Host "Module $Name is already imported." -ForegroundColor Green
    }   
}
#imports /installs require modules 
Write-Host "Importing required modules: Az.Resources, Az.Accounts, Microsoft.Graph.Authentication, ImportExcel" -ForegroundColor Cyan
Test-Module -Name Az.Resources
Test-Module -Name Az.Accounts
Test-Module -Name Microsoft.Graph.Authentication
Test-Module -Name ImportExcel
Write-Host "✅ All modules are installed and imported." -ForegroundColor Green
# Disconnect any existing sessions
Write-Host "Disconnecting any existing sessions..." -ForegroundColor Cyan
#disconnect-Mggraph -ErrorAction SilentlyContinue
#Disconnect-AzAccount  
Write-Host "✅ All sessions disconnected." -ForegroundColor Green
# Connect new sessions
Write-Host "Connecting to AzAccount..." -ForegroundColor Cyan
Disable-AzContextAutosave -Scope Process
Update-AzConfig -LoginExperienceV2 Off -Scope Process
#Connect-AzAccount
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
#Connect-MgGraph -Scopes 'RoleManagement.Read.Directory', 'User.Read.All', 'User.ReadBasic.All', 'User.Read', 'GroupMember.Read.All', 'Group.Read.All', 'Directory.Read.All', 'Directory.AccessAsUser.All', 'RoleEligibilitySchedule.Read.Directory', 'RoleManagement.Read.All', 'SecurityActions.Read.All', 'SecurityActions.ReadWrite.All', 'SecurityEvents.Read.All', "Organization.Read.All", "AuditLog.Read.All", "UserAuthenticationMethod.Read.All"   -ContextScope Process
Write-Host "✅ You are now fully connected!" -ForegroundColor Green


# Select folder for export 
Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "Please select a folder where the report will be saved." -ForegroundColor Cyan
Write-Host "⚠️  The folder selection window may appear behind other open windows." -ForegroundColor Yellow
Write-Host "If you don't see it, try minimizing other windows." -ForegroundColor Yellow
Write-Host "--------------------------------------------------------" -ForegroundColor DarkGray
Add-Type -AssemblyName System.Windows.Forms
$FileBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{ 
    InitialDirectory = [Environment]::GetFolderPath('Desktop') 
}
$result = $FileBrowser.ShowDialog(((New-Object System.Windows.Forms.Form -Property @{TopMost = $true })))
if ($result -eq [Windows.Forms.DialogResult]::OK) {
    $folder = $FileBrowser.SelectedPath
    Write-Host "Export folder selected: $folder" -ForegroundColor Green
}
else {
    Write-Host "❌ No folder selected. Exiting script." -ForegroundColor Red
    return
}
Write-Host "Caching All Users" -ForegroundColor Cyan

# igall "https://graph.microsoft.com/beta/users?`$select=Displayname%2CUserprincipalname%2CcompanyName%2CaccountEnabled%2CCreatedDatetime%2CLastPasswordChangeDateTime%2csignInActivity%2clastNonInteractiveSignInDateTime%2clastSignInDateTime" | Foreach-Object {
#     $cache.add($_.id, $_)
# }
Write-Host "✅ Retrieved all users" -ForegroundColor Green
#Get org displayname
Write-Host "Fetching organization display name..." -ForegroundColor Yellow
$orgdisplayname = igall https://graph.microsoft.com/beta/organization | Select-Object -ExpandProperty displayName
Write-Host "Organization: $orgdisplayname" -ForegroundColor Green
    
$date = Get-Date -Format yyyy-MM-dd
Write-Host "Fetching directory roles..." -ForegroundColor Yellow
$directoryRoles = igall https://graph.microsoft.com/beta/directoryRoles | foreach-object {
    [PsCustomObject]$_
}
Write-Host "✅ Retrieved $($directoryRoles.Count) directory roles." -ForegroundColor Green

# In a live tenant the will be a lot of instances so we filter
# on endDateTime to limit the responses to active instances
$now = (Get-Date -AsUTC).ToString("yyyy-MM-ddTHH:mm:ssZ")
Write-Host "Fetching active role assignments (PIM activated roles)..." -ForegroundColor Yellow
$assignmentSchedules = @()
$assignmentSchedules += igall  "https://graph.microsoft.com/beta/roleManagement/directory/roleAssignmentScheduleInstances?`$expand=roleDefinition,principal&`$filter=assignmentType eq 'Activated' and endDateTime ge $now" | ForEach-Object {
    [PsCustomObject]$_
} |
Where-Object {
    $_.RoleDefinitionId -in $directoryRoles.roleTemplateId
}
Write-Host "✅ Retrieved $($assignmentSchedules.Count) active assignment schedules." -ForegroundColor Green
# Fetch role assignments to be able to filter out
# admins that have used PIM to activate a role
Write-Host "Fetching assignment admins..." -ForegroundColor Yellow
$assignmentAdmins = @()
$assignmentAdmins += $assignmentSchedules | Where-Object {
    $_.principal.'@odata.type' -notmatch "#microsoft.graph.servicePrincipal"
} | ForEach-Object {
    $assignment = $_
    if ($_.principal.'@odata.type' -match '#microsoft.graph.group') {
        igall -Uri "https://graph.microsoft.com/beta/groups/$($assignment.principalId)/transitiveMembers" | ForEach-Object {
            $member = [pscustomobject]$_
            Add-Member -InputObject $member -NotePropertyName 'Role' -NotePropertyValue $assignment.roleDefinition.displayName -PassThru
        }
        
    }
    else {
        $member = Get-User -Id $_.principalId
        $member = $member | Select-Object *
        Add-Member -InputObject $member -NotePropertyName 'Role' -NotePropertyValue $assignment.roleDefinition.displayName -PassThru
    }
}
Write-Host "✅ Assignment admins processed." -ForegroundColor Green
Write-Host "Building administrator list..." -ForegroundColor Yellow
$administrators = $directoryRoles | ForEach-Object {
    $role = $_.displayName    
    Write-Host "───────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "🔹 Processing directory role: $role" -ForegroundColor Cyan
    Write-Host " → Fetching members of role '$role'..." -ForegroundColor DarkGray
    igall -Uri "https://graph.microsoft.com/beta/directoryRoles/$($_.id)/members" | ForEach-Object {
        $member = [PSCustomObject]$_
        if ($member.'@odata.type' -notmatch 'group|ServicePrincipal') {
            Write-Host "   ↳ Found user: $($member.displayName)" -ForegroundColor Cyan
            Write-Host "     → Getting user details from Graph..." -ForegroundColor DarkGray
            $user = Get-User -id $member.id 

            Write-Host "     → Adding user '$($user.DisplayName)' to role '$role'" -ForegroundColor Yellow
            
            $user.Roles += $role

            #$user.lastSignInDateTime = $member.signInActivity.lastSignInDateTime
               
            Write-Host "     ✅ Completed: $($user.DisplayName)" -ForegroundColor Green
            $user
        }
        elseif ($member.'@odata.type' -match 'group') {
            Write-Host "   ↳ Expanding group: $($member.displayName)" -ForegroundColor Cyan
            Write-Host "     → Fetching transitive members..." -ForegroundColor DarkGray

            igall -Uri "https://graph.microsoft.com/beta/groups/$($member.id)/transitiveMembers" | ForEach-Object {
                Write-Host "       ↳ Adding group member: $($_.displayName)" -ForegroundColor Yellow
                $member = [PSCustomObject]$_
                Add-Member -InputObject $member -NotePropertyName 'Role' -NotePropertyValue $role -PassThru  
                Write-Host "       ✅ Added $($member.DisplayName) (from group $($member.displayName))" -ForegroundColor Green
            }
            
        }
    }
} | Sort-Object -Property id | Sort-Object -Unique -Property id | 
Where-Object {
    # Filter out PIM activated admins as they
    # are displayed in the Eligible sheet
    $admin = $_
    $foundInAssignments = $assignmentAdmins | Where-Object {
        $admin.id -match $_.id -and $admin.Roles -contains $_.Role
    }
    -not $foundInAssignments
} 
#| Select-Object @{L='Roles';E={$_.Roles -join ','}}, displayName, Userprincipalname, companyName, AdminRiskScore, AdminRiskLevel, accountEnabled, CreatedDatetime , LastPasswordChangeDateTime, lastSignInDateTime, hasStrongMFA, StrongAuthCount, AuthPassword, AuthPhone, AuthFido2, AuthPasswordless, AuthMicrosoftAuthenticator, IsLicensed

Write-Host "✅ Administrator list compiled successfully." -ForegroundColor Green
Write-Host "───────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "Fetching eligible roles..." -ForegroundColor Yellow
$eligible = igall -Uri 'https://graph.microsoft.com/beta/roleManagement/directory/roleEligibilityScheduleInstances/?$expand=roleDefinition,principal' | ForEach-Object {
    $e = [PSCustomObject]$_
    $principal = [PSCustomObject]$e.principal
        
    if ($e.memberType -match 'Direct' -and $principal.'@odata.type' -notmatch 'group|ServicePrincipal') {
        Write-Host "Processing eligible direct user: $($principal.displayName)" -ForegroundColor Cyan
        Write-Host " → Fetching detailed info for $($principal.userPrincipalName)" -ForegroundColor DarkGray
        $user = Get-User -id $principal.id  
        Write-Host " → Adding role '$($e.roleDefinition["displayName"])' (MemberType: $($e.memberType))" -ForegroundColor Yellow
            
        $user.EligibleRoles += [pscustomobject]@{
            'Role'       = $e.roleDefinition.displayName
            'MemberType' = $e.memberType
        }

        $user
        Write-Host " ✅ Completed processing for $($principal.DisplayName)" -ForegroundColor Green

    }
    elseif ($principal.'@odata.type' -match 'group') {
        Write-Host "Expanding eligible group: $($e.principal.displayName)" -ForegroundColor Cyan
        Write-Host " → Fetching members from group ID: $($e.principalId)" -ForegroundColor DarkGray
        $groupMembers = igall -Uri "https://graph.microsoft.com/beta/groups/$($e.principalId)/transitiveMembers" | Sort-Object id -Unique
        $total = $groupMembers.Count
        $counter = 0
        $groupMembers | ForEach-Object  -Begin {
            Write-Progress -Activity "Expanding group: $($e.principal.displayName)" -Status "0 of $total members" -PercentComplete 0
        } -Process {
            $counter++
            $percent = [math]::Round(($counter / $total) * 100, 2)
            Write-Progress -Activity "Expanding group: $($e.principal.displayName)" -Status "$counter of $total members" -PercentComplete $percent
            if ($_.'@odata.type' -eq '#microsoft.graph.user') {

                $user = Get-User -id $_.id
            }
            elseif ($_.'@odata.type' -eq '#microsoft.graph.servicePrincipal') {
                $user = Get-ServicePrincipal -id $_.id
            }
            elseif ($_.'@odata.type' -eq '#microsoft.graph.group') {

                Write-Warning "Nested group detected: $($_.displayName)"

                $nested = [pscustomobject]@{
                    displayName                = $_.displayName
                    UserPrincipalName          = $null
                    EligibleRole               = $e.roleDefinition.displayName
                    DirectRole                 = $null
                    EligibleRoleGroup          = $e.principal.displayName
                    AdminRiskScore             = 7
                    AdminRiskLevel             = "Medium"
                    memberType                 = "NestedGroup"
                    createdDateTime            = $null
                    LastPasswordChangeDateTime = $null
                    lastSignInDateTime         = $null
                    hasStrongMFA               = $false
                    StrongAuthCount            = 0
                    AuthPassword               = $null
                    AuthPhone                  = $null
                    AuthFido2                  = $null
                    AuthPasswordless           = $null
                    AuthMicrosoftAuthenticator = $null
                }

                $nested

                continue
            }
            $user.EligibleRoles += [pscustomobject]@{
                'Role'       = $e.roleDefinition["displayName"]
                'MemberType' = 'Group'
                'Group' = $e.principal.displayname
            }

            $user
            Write-Host "     ✅ Added $($member.DisplayName) from group $($e.principal.displayName)" -ForegroundColor Green
        } -End {
            Write-Progress -Activity "Expanding group: $($e.principal.displayName)" -Completed
            Write-Host "✅ Finished expanding group $($e.principal.displayName) ($total members)" -ForegroundColor Green
        }
    }
} | Sort-Object -Property id | Sort-Object -Unique -Property id

Write-Host "✅ Finished collecting all eligible role assignments." -ForegroundColor Green
Write-Host "Fetching Azure role assignments..." -ForegroundColor Yellow
$azroles = Get-AzSubscription | ForEach-Object {
    $id = $_.id 
    $name = $_.name 

    Write-Host "Fetching role assignments for subscription: $name" -ForegroundColor DarkCyan

    Get-AzRoleAssignment -Scope /subscriptions/$id | ForEach-Object {

        $assignment = $_
        $assignmentSource = "Direct"

        if ($assignment.ObjectType -eq "Group") {
            $assignmentSource = "Group"
        }

        if ($assignment.ObjectType -eq "User") {
            $user = Get-User -Id $assignment.ObjectId
        } elseif ($assignment.ObjectType -match "ServicePrincipal") {
            $user = Get-ServicePrincipal -Id $assignment.ObjectId
            if (-not $user) {
                return
            }
        } else {
            Write-Warning "Unknown ObjectType '$($assignment.ObjectType)'"
            return
        }

        $user.AzureRoles += [pscustomobject]@{
            'RoleDefinitionName' = $assignment.RoleDefinitionName
            'MemberType' = $assignmentSource
            'Subscription' = $name
        }

      $user
    }

} #| Select-Object roleDefinitionName, displayname, SigninName, ObjectId, ObjectType, AssignmentSource, Subscription, AdminRiskScore, AdminRiskLevel, IsLicensed, ProductivityServicesEnabled

foreach( $admin in $administrators + $eligible + $azroles) {
    $riskScore = Get-AdminRiskScore -User $admin
    $riskLevel = Get-AdminRiskLevel $riskScore

    $admin.AdminRiskScore = $riskScore
    $admin.AdminRiskLevel = $riskLevel
}




Write-Host "✅ Azure role assignments gathered." -ForegroundColor Green

$exportPath = "$folder\$orgdisplayname-EntraIDAdminReport$date.xlsx"
if (Test-Path $exportPath) {
    Write-Host "Removing existing report..." -ForegroundColor Yellow
    Remove-Item $exportPath -Force
}
$allAdmins = $administrators + $eligible + $azroles | Sort-Object -Property id | Sort-Object -Property id -Unique

$allAdmins = $allAdmins | Select-Object @{L='Roles';E={$_.Roles -join ','}},@{L='EligibleRoles';E={$_.EligibleRoles.Role -join ','}},@{L='AzureRoles';E={$_.AzureRoles.RoleDefinitionName -join ','}},displayName, Userprincipalname, companyName, AdminRiskScore, AdminRiskLevel, accountEnabled, CreatedDatetime , LastPasswordChangeDateTime, lastSignInDateTime, hasStrongMFA, StrongAuthCount, AuthPassword, AuthPhone, AuthFido2, AuthPasswordless, AuthMicrosoftAuthenticator, IsLicensed

$eligible = $eligible | ForEach-Object {
    $e = $_
    $e.EligibleRoles | foreach-object {
        $e.PSObject.Copy() |
        Add-Member -NotePropertyName 'MemberType' -NotePropertyValue $_.MemberType -Passthru |
        Add-Member -NotePropertyName 'DirectRole' -NotePropertyValue $_.MemberType -Passthru |
        Add-Member -NotePropertyName 'EligibleRoleGroup' -NotePropertyValue $_.Role -Passthru
    }
}
# -------------------------
# Administrators
# -------------------------
# $allAdmins += $administrators | ForEach-Object {
#     [PSCustomObject]@{
#         UserPrincipalName           = $_.UserPrincipalName
#         ObjectId                    = $_.Id
#         displayName                 = $_.displayName
#         Role                        = $_.Roles -join ', '
#         Source                      = "Active"
#         hasStrongMFA                = $_.hasStrongMFA
#         AdminRiskScore              = $_.AdminRiskScore
#         AdminRiskLevel              = $_.AdminRiskLevel
#         lastSignInDateTime          = $_.lastSignInDateTime
#         ProductivityServicesEnabled = $_.ProductivityServicesEnabled
#     }
# }

# -------------------------
# Eligible Roles
# -------------------------
# $allAdmins += $eligible | ForEach-Object {
#     [PSCustomObject]@{
#         UserPrincipalName           = $_.UserPrincipalName
#         ObjectId                    = $_.Id
#         Role                        = $_.EligibleRole
#         Source                      = "Eligible"
#         hasStrongMFA                = $_.hasStrongMFA
#         AdminRiskScore              = $_.AdminRiskScore
#         AdminRiskLevel              = $_.AdminRiskLevel
#         lastSignInDateTime          = $_.lastSignInDateTime
#         ProductivityServicesEnabled = $_.ProductivityServicesEnabled
#     }
# }

# -------------------------
# Azure Roles
# -------------------------
# $allAdmins += $azroles | Where-Object ObjectType -eq "User" | ForEach-Object {
#     [PSCustomObject]@{
#         UserPrincipalName           = $_.SignInName
#         ObjectId                    = $_.ObjectId
#         Role                        = $_.RoleDefinitionName
#         Source                      = "Azure"
#         hasStrongMFA                = $false
#         AdminRiskScore              = $_.AdminRiskScore
#         AdminRiskLevel              = $_.AdminRiskLevel
#         lastSignInDateTime          = $null
#         ProductivityServicesEnabled = $false
#     }
# }

# -------------------------
# CLEAN + DEDUPE
# -------------------------



# $allAdmins = $allAdmins |
# Where-Object { $_ -and $_.UserPrincipalName } |
# Group-Object UserPrincipalName |
# ForEach-Object {

#     $entries = $_.Group

#     $allRoles = ($entries.Role -split ', ' | Sort-Object -Unique)

#     $maxScore = ($entries.AdminRiskScore | Measure-Object -Maximum).Maximum
#     $level = Get-AdminRiskLevel $maxScore

#     [PSCustomObject]@{
#         UserPrincipalName           = $entries[0].UserPrincipalName
#         ObjectId                    = $_.Name
#         displayName                 = ($entries.displayName | Select-Object -First 1)
#         Role                        = ($allRoles -join ', ')
#         hasStrongMFA                = ($entries.hasStrongMFA -contains $true)
#         AdminRiskScore              = $maxScore
#         AdminRiskLevel              = $level
#         lastSignInDateTime          = ($entries.lastSignInDateTime | Sort-Object -Descending | Select-Object -First 1)
#         ProductivityServicesEnabled = ($entries.ProductivityServicesEnabled -contains $true)
#     }
# }

$topRiskAdmins = $allAdmins |
Sort-Object AdminRiskScore -Descending |
Select-Object -First 10 @{
    Name       = 'displayName'
    Expression = {
        if ($_.displayName) { $_.displayName }
        else { ($_.UserPrincipalName -split "@")[0] }
    }
}, Role, AdminRiskScore, AdminRiskLevel
$topRiskAdmins = $topRiskAdmins | Sort-Object AdminRiskScore -Descending


# ----------------------------------------------------
# Summary metrics
# ----------------------------------------------------
$totalAdmins = $allAdmins.Count

$criticalAdmins = ($allAdmins | Where-Object { $_.AdminRiskLevel -eq "Critical" }).Count
$highAdmins = ($allAdmins | Where-Object { $_.AdminRiskLevel -eq "High" }).Count
$mediumAdmins = ($allAdmins | Where-Object { $_.AdminRiskLevel -eq "Medium" }).Count
$lowAdmins = ($allAdmins | Where-Object { $_.AdminRiskLevel -eq "Low" }).Count

$noMFAAdmins = ($allAdmins | Where-Object { -not $_.hasStrongMFA }).Count

$inactiveAdmins = ($allAdmins | Where-Object {
        $_.lastSignInDateTime -and
        [datetime]$_.lastSignInDateTime -lt (Get-Date).AddDays(-90)
    }).Count

$productivityAdmins = ($allAdmins | Where-Object {
        $_.ProductivityServicesEnabled -eq $true
    }).Count

# ----------------------------------------------------
# Largest Risk Calculation
# ----------------------------------------------------

$risks = @()

$risks += [PSCustomObject]@{
    Name  = "Missing MFA on admins"
    Count = $noMFAAdmins
}

$risks += [PSCustomObject]@{
    Name  = "Critical role exposure"
    Count = $criticalAdmins
}

$risks += [PSCustomObject]@{
    Name  = "Inactive privileged accounts"
    Count = $inactiveAdmins
}

$risks += [PSCustomObject]@{
    Name  = "Admins with M365 access"
    Count = $productivityAdmins
}

$largestRisk = $risks |
Where-Object { $_.Count -gt 0 } |
Sort-Object Count -Descending |
Select-Object -First 1


$allAdmins | Export-Excel `
    -Path $exportPath `
    -WorksheetName "All Admins" `
    -TableName AllAdminsTable `
    -AutoSize `

#Inactive data 

$activityTable = @(
    [PSCustomObject]@{ Status = "Active"; Count = $totalAdmins - $inactiveAdmins }
    [PSCustomObject]@{ Status = "Inactive"; Count = $inactiveAdmins }
)

$activityTable | Export-Excel `
    -Path $exportPath `
    -WorksheetName "Activity Data" `
    -TableName ActivityTable `
    -AutoSize `
    -Append

# MFA DATA
$mfaStatuses = @("Strong MFA", "No MFA")

$mfaTable = foreach ($status in $mfaStatuses) {

    if ($status -eq "Strong MFA") {
        $count = ($allAdmins | Where-Object { $_.hasStrongMFA }).Count
    }
    else {
        $count = ($allAdmins | Where-Object { -not $_.hasStrongMFA }).Count
    }

    [PSCustomObject]@{
        MFAStatus = $status
        Count     = $count
    }
}
$mfaTable | Export-Excel `
    -Path $exportPath `
    -WorksheetName "MFA Data" `
    -TableName 'MfaTable' `
    -AutoSize `
    -Append

# ----------------------------
# Risk Data
# -----------------------------

$riskLevels = @("Critical", "High", "Medium", "Low")

$riskTable = @(
    foreach ($level in $riskLevels) {

        $count = @($allAdmins | Where-Object { $_.AdminRiskLevel -eq $level }).Count

        [PSCustomObject]@{
            RiskLevel = $level
            Count     = $count
        }
    }
)

$riskTable | Format-Table
$riskTable | Get-Member
$riskTable.Count

$riskTable | Export-Excel `
    -Path $exportPath `
    -WorksheetName "Risk Data" `
    -TableName 'RiskTable' `
    -AutoSize `
    -Append

Write-Host "MFA rows: $($mfaTable.Count)"
Write-Host "Risk rows: $($riskTable.Count)"



# ---------------------------------
# TopRiskAdmins Data 
# ---------------------------------

$topRiskAdmins | Export-Excel `
    -Path $exportPath `
    -WorksheetName "TopRiskAdmin Data" `
    -TableName 'TopRiskAdmins' `
    -AutoSize `
    -Append






# ----------------------------------------------------
# Identity Posture Score
# ----------------------------------------------------

$total = $totalAdmins

# -----------------------------
# Calculate normalized score
# -----------------------------
$postureScore = 100

if ($total -gt 0) {
    $postureScore -= (($noMFAAdmins / $total) * 40)
    $postureScore -= (($criticalAdmins / $total) * 30)
    $postureScore -= (($inactiveAdmins / $total) * 20)
    $postureScore -= (($productivityAdmins / $total) * 10)
}

$postureScore = [math]::Round($postureScore, 0)
if ($postureScore -lt 0) { $postureScore = 0 }

# -----------------------------
# Level (human readable)
# -----------------------------
switch ($postureScore) {
    { $_ -ge 90 } { $postureLevel = "Excellent"; break }
    { $_ -ge 75 } { $postureLevel = "Good"; break }
    { $_ -ge 50 } { $postureLevel = "Moderate Risk"; break }
    default { $postureLevel = "High Risk" }
}

# -----------------------------
# Grade (executive friendly)
# -----------------------------
switch ($postureScore) {
    { $_ -ge 85 } { $grade = "A"; break }
    { $_ -ge 70 } { $grade = "B"; break }
    { $_ -ge 50 } { $grade = "C"; break }
    { $_ -ge 30 } { $grade = "D"; break }
    default { $grade = "F" }
}

# -----------------------------
# UX label 
# -----------------------------
$postureLabel = "$postureScore ($postureLevel - Grade $grade)"

# -----------------------------
# Export Object
# -----------------------------
$posture = @(
    [PSCustomObject]@{ Metric = "Privileged Identity Security Score"; Value = $postureScore }
    [PSCustomObject]@{ Metric = "Posture Level"; Value = $postureLevel }
    [PSCustomObject]@{ Metric = "Security Grade"; Value = $grade }
    [PSCustomObject]@{ Metric = "Display"; Value = $postureLabel }
)
# ----------------------------------------------------
# Build summary dataset
# ----------------------------------------------------

$summary = @(
    [PSCustomObject]@{ Metric = "Total Administrators"; Value = $totalAdmins }
    [PSCustomObject]@{ Metric = "Critical Risk Admins"; Value = $criticalAdmins }
    [PSCustomObject]@{ Metric = "High Risk Admins"; Value = $highAdmins }
    [PSCustomObject]@{ Metric = "Medium Risk Admins"; Value = $mediumAdmins }
    [PSCustomObject]@{ Metric = "Low Risk Admins"; Value = $lowAdmins }
    [PSCustomObject]@{ Metric = "Admins without Strong MFA"; Value = $noMFAAdmins }
    [PSCustomObject]@{ Metric = "Admins with Productivity Services"; Value = $productivityAdmins }
    [PSCustomObject]@{ Metric = "Inactive Admins (>90 days)"; Value = $inactiveAdmins }


)

# ----------------------------------------------------
# Dashboard dataset
# ----------------------------------------------------

$dashboard = @(
    [PSCustomObject]@{ Metric = "Total Admins"; Value = $totalAdmins }
    [PSCustomObject]@{ Metric = "Critical Admins"; Value = $criticalAdmins }
    [PSCustomObject]@{ Metric = "High Risk Admins"; Value = $highAdmins }
    [PSCustomObject]@{ Metric = "Medium Risk Admins"; Value = $mediumAdmins }
    [PSCustomObject]@{ Metric = "Low Risk Admins"; Value = $lowAdmins }
    [PSCustomObject]@{ Metric = "Admins without MFA"; Value = $noMFAAdmins }
    [PSCustomObject]@{ Metric = "Inactive Admins"; Value = $inactiveAdmins }
    [PSCustomObject]@{ Metric = "Admins with Productivity Services"; Value = $productivityAdmins }
)

$riskDistribution = @(
    [PSCustomObject]@{ RiskLevel = "Critical"; Count = $criticalAdmins }
    [PSCustomObject]@{ RiskLevel = "High"; Count = $highAdmins }
    [PSCustomObject]@{ RiskLevel = "Medium"; Count = $mediumAdmins }
    [PSCustomObject]@{ RiskLevel = "Low"; Count = $lowAdmins }
)
Write-Host "Exporting data to Excel..." -ForegroundColor Cyan




# Administrators
$administrators | Select-Object @{L='Roles';E={$_.Roles -join ','}},displayName, Userprincipalname, companyName, AdminRiskScore, AdminRiskLevel, accountEnabled, CreatedDatetime , LastPasswordChangeDateTime, lastSignInDateTime, hasStrongMFA, StrongAuthCount, AuthPassword, AuthPhone, AuthFido2, AuthPasswordless, AuthMicrosoftAuthenticator, IsLicensed | 
Export-Excel `
    -NoNumberConversion * `
    -Path $exportPath `
    -WorksheetName "Administrators" `
    -TableName Administrators `
    -FreezeTopRow `
    -AutoSize `
    -TableStyle Medium2 `
    -Append

# Eligible Roles
$eligible |  Select-Object id, displayName, Userprincipalname, DirectRole, EligibleRoleGroup, memberType, AdminRiskScore, AdminRiskLevel, createdDateTime, LastPasswordChangeDateTime, lastSignInDateTime, hasStrongMFA, StrongAuthCount, AuthPassword, AuthPhone, AuthFido2, AuthPasswordless, AuthMicrosoftAuthenticator, IsLicensed |
Export-Excel `
    -NoNumberConversion * `
    -Path $exportPath `
    -WorksheetName "Eligible Roles" `
    -TableName EligibleRoles `
    -FreezeTopRow `
    -AutoSize `
    -Append `
    -TableStyle Medium2

# Azure Roles
$azroles | Select-Object @{L='AzureRoles';E={$_.AzureRoles.RoleDefinitionName -join ','}},displayName, Userprincipalname, companyName, AdminRiskScore, AdminRiskLevel, accountEnabled, CreatedDatetime , LastPasswordChangeDateTime, lastSignInDateTime, hasStrongMFA, StrongAuthCount, AuthPassword, AuthPhone, AuthFido2, AuthPasswordless, AuthMicrosoftAuthenticator, IsLicensed |
Export-Excel `
    -NoNumberConversion * `
    -Path $exportPath `
    -WorksheetName "Azure Roles" `
    -TableName AzureRoles `
    -FreezeTopRow `
    -AutoSize `
    -Append `
    -TableStyle Medium2



# ----------------------------------------------------
# Dashboard Charts
# ----------------------------------------------------

$posture | Export-Excel `
    -Path $exportPath `
    -WorksheetName "Identity Posture" `
    -TableName IdentityPosture `
    -AutoSize `
    -Append `
    -TableStyle Medium2







Write-Host "Adding conditional formatting..." -ForegroundColor Cyan

$excel = Open-ExcelPackage $exportPath
$excel.Workbook.Worksheets["All Admins"].Hidden = "Hidden"
$excel.Workbook.Worksheets["Activity Data"].Hidden = "Hidden"
$excel.Workbook.Worksheets["TopRiskAdmin Data"].Hidden = "Hidden"
$excel.Workbook.Worksheets["Identity Posture"].Hidden = "Hidden"
$excel.Workbook.Worksheets["MFA Data"].Hidden = "Hidden"
$excel.Workbook.Worksheets["Risk Data"].Hidden = "Hidden"
$adminRows = $administrators.Count + 1
$eligibleRows = $eligible.Count + 1
$azRows = $azroles.Count + 1
$topRows = $topRiskAdmins.Count + 1







# Administrators sheet
$ws = $excel.Workbook.Worksheets["Administrators"]

Add-ConditionalFormatting -Worksheet $ws -Address "F2:F$adminRows" `
    -RuleType ContainsText `
    -ConditionValue "Critical" `
    -BackgroundColor Red

Add-ConditionalFormatting -Worksheet $ws -Address "F2:F$adminRows" `
    -RuleType ContainsText `
    -ConditionValue "High" `
    -BackgroundColor Orange

Add-ConditionalFormatting -Worksheet $ws -Address "F2:F$adminRows" `
    -RuleType ContainsText `
    -ConditionValue "Medium" `
    -BackgroundColor Yellow

Add-ConditionalFormatting -Worksheet $ws -Address "F2:F$adminRows" `
    -RuleType ContainsText `
    -ConditionValue "Low" `
    -BackgroundColor LightGreen

# Eligible Sheet 

$ws = $excel.Workbook.Worksheets["Eligible Roles"]

Add-ConditionalFormatting -Worksheet $ws -Address "H2:H$eligibleRows" `
    -RuleType ContainsText `
    -ConditionValue "Critical" `
    -BackgroundColor Red

Add-ConditionalFormatting -Worksheet $ws -Address "H2:H$eligibleRows" `
    -RuleType ContainsText `
    -ConditionValue "High" `
    -BackgroundColor Orange

Add-ConditionalFormatting -Worksheet $ws -Address "H2:H$eligibleRows" `
    -RuleType ContainsText `
    -ConditionValue "Medium" `
    -BackgroundColor Yellow

Add-ConditionalFormatting -Worksheet $ws -Address "H2:H$eligibleRows" `
    -RuleType ContainsText `
    -ConditionValue "Low" `
    -BackgroundColor LightGreen
# Azure Roles  Sheet 

$ws = $excel.Workbook.Worksheets["Azure Roles"]

Add-ConditionalFormatting -Worksheet $ws -Address "I2:I$azRows" `
    -RuleType ContainsText `
    -ConditionValue "Critical" `
    -BackgroundColor Red

Add-ConditionalFormatting -Worksheet $ws -Address "I2:I$azRows" `
    -RuleType ContainsText `
    -ConditionValue "High" `
    -BackgroundColor Orange

Add-ConditionalFormatting -Worksheet $ws -Address "I2:I$azRows" `
    -RuleType ContainsText `
    -ConditionValue "Medium" `
    -BackgroundColor Yellow

Add-ConditionalFormatting -Worksheet $ws -Address "I2:I$azRows" `
    -RuleType ContainsText `
    -ConditionValue "Low" `
    -BackgroundColor LightGreen







# -----------------------------
# Traffic light icons for score
# -----------------------------

<#Add-ConditionalFormatting `
    -Worksheet $ws2 `
    -Address "D2:D$topRows" `
    -ThreeIconsSet TrafficLights1 `
    -Reverse #>
# ----------------------------------------------------
# SELF-CONTAINED DASHBOARD
# ----------------------------------------------------


$ws = $excel.Workbook.Worksheets["Identity Dashboard"]
if (-not $ws) {
    $ws = $excel.Workbook.Worksheets.Add("Identity Dashboard")
}
# Move dashboard to first
$excel.Workbook.View.ActiveTab = $ws.Index - 1
$ws.Select()
# Remove default borders 
$ws.Cells.Style.Border.Top.Style = "None"
$ws.Cells.Style.Border.Bottom.Style = "None"
$ws.Cells.Style.Border.Left.Style = "None"
$ws.Cells.Style.Border.Right.Style = "None"
$ws.Cells.Style.Fill.PatternType = "Solid"
$ws.Cells.Style.Fill.BackgroundColor.SetColor(
    [System.Drawing.Color]::FromArgb(248, 248, 250)
)

# ----------------------------------------------------
# BACKGROUND CONTAINER
# ----------------------------------------------------

$dashboardRange = "B2:O75"
$ws.Column(1).Width = 5

# Clean background
$ws.Cells[$dashboardRange].Style.Fill.PatternType = "Solid"
$ws.Cells[$dashboardRange].Style.Fill.BackgroundColor.SetColor(
    [System.Drawing.Color]::FromArgb(248, 248, 250)
)
$ws.Cells["A2:O2"].Style.Border.Top.Style = "Medium"
$ws.Cells["A75:O75"].Style.Border.Bottom.Style = "Medium"
$ws.Cells["A2:A75"].Style.Border.Left.Style = "Medium"
$ws.Cells["O2:O75"].Style.Border.Right.Style = "Medium"



# ----------------------------------------------------
# REMOVE GRIDLINES (FIX)
# ----------------------------------------------------
try {
    $ws.View.ShowGridLines = $false
}
catch {
    Write-Host "Gridlines property not available, applying fallback..." -ForegroundColor Yellow
    
    # Fallback: make gridlines invisible by setting background
    $ws.Cells.Style.Fill.PatternType = "Solid"
    $ws.Cells.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::White)
}

# ----------------------------------------------------
# COLUMN WIDTHS 
# ----------------------------------------------------
1..15 | ForEach-Object {
    $ws.Column($_).Width = 18
}
# ROW SPACING 
$ws.Row(5).Height = 20   # mellan KPI och cards
$ws.Row(12).Height = 25  # mellan cards och charts
$ws.Row(20).Height = 25  # mellan charts och bar chart
# ----------------------------------------------------
# ROW HEIGHT (SPACING FOR CARDS)
# ----------------------------------------------------
$ws.Row(6).Height = 45
$ws.Row(7).Height = 45
$ws.Row(8).Height = 35
$ws.Row(9).Height = 35
$ws.Row(10).Height = 35

# ----------------------------------------------------
# TITLE
# ----------------------------------------------------
$ws.Cells["A1"].Value = "Entra Administrator Identity Security Dashboard"
$ws.Cells["A1:O1"].Merge = $true
$ws.Cells["A1"].Style.Font.Size = 28
$ws.Cells["A1"].Style.Font.Bold = $true
$ws.Cells["A1"].Style.HorizontalAlignment = "Center"

$ws.Cells["A1"].Style.Fill.PatternType = "Solid"
$ws.Cells["A1"].Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(122, 31, 162))
$ws.Cells["A1"].Style.Font.Color.SetColor([System.Drawing.Color]::White)

# ----------------------------------------------------
# KPI CARDS
# ----------------------------------------------------
# KPI GRID (centered)
$ws.Cells["C3:D3"].Merge = $true
$ws.Cells["C4:D4"].Merge = $true

$ws.Cells["F3:G3"].Merge = $true
$ws.Cells["F4:G4"].Merge = $true

$ws.Cells["I3:J3"].Merge = $true
$ws.Cells["I4:J4"].Merge = $true

$ws.Cells["L3:M3"].Merge = $true
$ws.Cells["L4:M4"].Merge = $true

# Values (reuse your variables)
$ws.Cells["C3"].Value = "Total Admins"
$ws.Cells["C4"].Value = $totalAdmins

$ws.Cells["F3"].Value = "Critical"
$ws.Cells["F4"].Value = $criticalAdmins

$ws.Cells["I3"].Value = "No MFA"
$ws.Cells["I4"].Value = $noMFAAdmins

$ws.Cells["L3"].Value = "Inactive"
$ws.Cells["L4"].Value = $inactiveAdmins

# Style KPI cards
function Set-KPI {
    param($range)

    $ws.Cells[$range].Style.Fill.PatternType = "Solid"
    $ws.Cells[$range].Style.Fill.BackgroundColor.SetColor(
        [System.Drawing.Color]::FromArgb(255, 255, 255)
    )

    $ws.Cells[$range].Style.HorizontalAlignment = "Center"
    $ws.Cells[$range].Style.VerticalAlignment = "Center"

    $ws.Cells[$range].Style.Border.BorderAround("Thin")
}

Set-KPI "C3:D4"
Set-KPI "F3:G4"
Set-KPI "I3:J4"
Set-KPI "L3:M4"
$ws.Cells["C3:M3"].Style.Font.Color.SetColor([System.Drawing.Color]::DimGray)
$ws.Cells["C4:M4"].Style.Font.Size = 14
$ws.Cells["C4:M4"].Style.Font.Size = 18
$ws.Cells["C4:M4"].Style.Font.Bold = $true

# ----------------------------------------------------
# HERO AREA (Risk + Posture)
# ----------------------------------------------------

# LEFT CARD (PRIMARY RISK)
$riskRange = $ws.Cells["C6:G11"]
$riskRange.Merge = $true

$riskRange.Style.Fill.PatternType = "Solid"
$riskRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]::FromArgb(255, 240, 200))
$riskRange.Style.Border.BorderAround("Thin")
$riskRange.Style.HorizontalAlignment = "Center"
$riskRange.Style.VerticalAlignment = "Center"

$riskCell = $ws.Cells["C6"]
$riskCell.Value = ""
$riskCell.Style.WrapText = $true

# TEXT
if ($largestRisk) {
    $textTitle = "⚠ PRIMARY RISK"
    $textMain = $largestRisk.Name
    $textSub = "$($largestRisk.Count) admins affected"
}
else {
    $textTitle = "PRIMARY RISK"
    $textMain = "No major risks detected"
    $textSub = ""
}

$rt = $riskCell.RichText
$rt.Clear()

$t1 = $rt.Add("$textTitle`n")
$t1.Size = 14
$t1.Color = [System.Drawing.Color]::DimGray

$t2 = $rt.Add("$textMain`n")
$t2.Bold = $true
$t2.Size = 24
$t2.Color = [System.Drawing.Color]::DarkOrange

$t3 = $rt.Add("$textSub")
$t3.Size = 14
$t3.Color = [System.Drawing.Color]::Gray


# RIGHT CARD (POSTURE SCORE)

if ($postureScore -ge 85) {
    $scoreColor = [System.Drawing.Color]::FromArgb(0, 150, 0)
    $scoreBg = [System.Drawing.Color]::FromArgb(220, 255, 220)
}
elseif ($postureScore -ge 60) {
    $scoreColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
    $scoreBg = [System.Drawing.Color]::FromArgb(255, 240, 200)
}
else {
    $scoreColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
    $scoreBg = [System.Drawing.Color]::FromArgb(255, 220, 220)
}
$scoreRange = $ws.Cells["H6:M11"]
$scoreRange.Merge = $true

$scoreRange.Style.Fill.PatternType = "Solid"
$scoreRange.Style.Fill.BackgroundColor.SetColor([System.Drawing.Color]$scoreBg)
$scoreRange.Style.Border.BorderAround("Thin")
$scoreRange.Style.HorizontalAlignment = "Center"
$scoreRange.Style.VerticalAlignment = "Center"

$scoreCell = $ws.Cells["H6"]
$scoreCell.Value = ""
$scoreCell.Style.WrapText = $true

$rt = $scoreCell.RichText
$rt.Clear()

$t1 = $rt.Add("Identity Security Score`n")
$t1.Size = 14
$t1.Color = [System.Drawing.Color]::DimGray

$t2 = $rt.Add("$postureScore`n")
$t2.Bold = $true
$t2.Size = 36
$t2.Color = [System.Drawing.Color]$scoreColor

$t3 = $rt.Add("$postureLevel`n")
$t3.Size = 14
$t3.Color = [System.Drawing.Color]::DimGray

$t4 = $rt.Add("Grade $grade")
$t4.Size = 12
$t4.Color = [System.Drawing.Color]::Gray


# ----------------------------------------------------
# CHARTS
# ----------------------------------------------------



# Risk
Add-ExcelChart `
    -Worksheet $ws `
    -ChartType Doughnut `
    -Title "Admin Risk Distribution" `
    -XRange "RiskTable[RiskLevel]" `
    -YRange "RiskTable[Count]" `
    -Row 16 `
    -Column 2 `
    -Width 390 `
    -Height 300
$chart = $ws.Drawings[-1]
$chart.Style = 26

# FIX COLORS
$chartXml = $chart.ChartXml

$ns = New-Object System.Xml.XmlNamespaceManager($chartXml.NameTable)
$ns.AddNamespace("c", "http://schemas.openxmlformats.org/drawingml/2006/chart")
$ns.AddNamespace("a", "http://schemas.openxmlformats.org/drawingml/2006/main")

$points = $chartXml.SelectNodes("//c:ser/c:dPt", $ns)

# Ensure datapoints exist 
if ($points.Count -eq 0) {
    $serNode = $chartXml.SelectSingleNode("//c:ser", $ns)

    0..3 | ForEach-Object {
        $dPt = $chartXml.CreateElement("c:dPt", $ns.LookupNamespace("c"))

        $idx = $chartXml.CreateElement("c:idx", $ns.LookupNamespace("c"))
        $idx.SetAttribute("val", $_)

        $spPr = $chartXml.CreateElement("c:spPr", $ns.LookupNamespace("c"))
        $solidFill = $chartXml.CreateElement("a:solidFill", $ns.LookupNamespace("a"))
        $srgbClr = $chartXml.CreateElement("a:srgbClr", $ns.LookupNamespace("a"))

        switch ($_) {
            0 { $srgbClr.SetAttribute("val", "C00000") } # Critical (red)
            1 { $srgbClr.SetAttribute("val", "FF8C00") } # High (orange)
            2 { $srgbClr.SetAttribute("val", "5B9BD5") } # Medium (neutral blue)
            3 { $srgbClr.SetAttribute("val", "00B050") } # Low (green)
        }

        $solidFill.AppendChild($srgbClr) | Out-Null
        $spPr.AppendChild($solidFill) | Out-Null
        $dPt.AppendChild($idx) | Out-Null
        $dPt.AppendChild($spPr) | Out-Null

        $serNode.AppendChild($dPt) | Out-Null
    }
}







#Inactive
Add-ExcelChart `
    -Worksheet $ws `
    -ChartType Doughnut `
    -Title "Admin Activity (90 days)" `
    -XRange "ActivityTable[Status]" `
    -YRange "ActivityTable[Count]" `
    -Row 16 `
    -Column 6 `
    -Width 390 `
    -Height 300

$chart = $ws.Drawings[-1]
$chart.Style = 26

$chartXml = $chart.ChartXml

$ns = New-Object System.Xml.XmlNamespaceManager($chartXml.NameTable)
$ns.AddNamespace("c", "http://schemas.openxmlformats.org/drawingml/2006/chart")
$ns.AddNamespace("a", "http://schemas.openxmlformats.org/drawingml/2006/main")

$serNode = $chartXml.SelectSingleNode("//c:ser", $ns)

0..1 | ForEach-Object {

    $dPt = $chartXml.CreateElement("c:dPt", $ns.LookupNamespace("c"))

    $idx = $chartXml.CreateElement("c:idx", $ns.LookupNamespace("c"))
    $idx.SetAttribute("val", $_)

    $spPr = $chartXml.CreateElement("c:spPr", $ns.LookupNamespace("c"))
    $solidFill = $chartXml.CreateElement("a:solidFill", $ns.LookupNamespace("a"))
    $srgbClr = $chartXml.CreateElement("a:srgbClr", $ns.LookupNamespace("a"))

    switch ($_) {
        0 { $srgbClr.SetAttribute("val", "00B050") } # Active = green
        1 { $srgbClr.SetAttribute("val", "FF8C00") } # Inactive = orange
    }

    $solidFill.AppendChild($srgbClr) | Out-Null
    $spPr.AppendChild($solidFill) | Out-Null
    $dPt.AppendChild($idx) | Out-Null
    $dPt.AppendChild($spPr) | Out-Null

    $serNode.AppendChild($dPt) | Out-Null
}

# MFA
Add-ExcelChart `
    -Worksheet $ws `
    -ChartType Doughnut `
    -Title "MFA Coverage" `
    -XRange "MfaTable[MFAStatus]" `
    -YRange "MfaTable[Count]" `
    -Row 16 `
    -Column 10 `
    -Width 390 `
    -Height 300



$chart = $ws.Drawings[-1]
$chart.Style = 26

$chartXml = $chart.ChartXml

$ns = New-Object System.Xml.XmlNamespaceManager($chartXml.NameTable)
$ns.AddNamespace("c", "http://schemas.openxmlformats.org/drawingml/2006/chart")
$ns.AddNamespace("a", "http://schemas.openxmlformats.org/drawingml/2006/main")

$serNode = $chartXml.SelectSingleNode("//c:ser", $ns)

0..1 | ForEach-Object {
    $dPt = $chartXml.CreateElement("c:dPt", $ns.LookupNamespace("c"))

    $idx = $chartXml.CreateElement("c:idx", $ns.LookupNamespace("c"))
    $idx.SetAttribute("val", $_)

    $spPr = $chartXml.CreateElement("c:spPr", $ns.LookupNamespace("c"))
    $solidFill = $chartXml.CreateElement("a:solidFill", $ns.LookupNamespace("a"))
    $srgbClr = $chartXml.CreateElement("a:srgbClr", $ns.LookupNamespace("a"))

    switch ($_) {
        0 { $srgbClr.SetAttribute("val", "00B050") } # Strong MFA = green
        1 { $srgbClr.SetAttribute("val", "C00000") } # No MFA = red
    }

    $solidFill.AppendChild($srgbClr) | Out-Null
    $spPr.AppendChild($solidFill) | Out-Null
    $dPt.AppendChild($idx) | Out-Null
    $dPt.AppendChild($spPr) | Out-Null

    $serNode.AppendChild($dPt) | Out-Null
}

# Top admins
Add-ExcelChart `
    -Worksheet $ws `
    -ChartType BarClustered `
    -Title "Top 10 Highest Risk Admins" `
    -XRange "TopRiskAdmins[displayName]" `
    -YRange "TopRiskAdmins[AdminRiskScore]" `
    -Row 32 `
    -Column 2 `
    -Width 1400 `
    -Height 500

$chart = $ws.Drawings | Where-Object {
    $_.Title.Text -eq "Top 10 Highest Risk Admins"
}

# Clean look
$chart.Style = 26

# Remove legend 
$chart.Legend.Remove()



# Data labels 
$chart.DataLabel.ShowValue = $true




# -----------------------------------
# COLOR BY RISK LEVEL (🔥 viktig)
# -----------------------------------

$chartXml = $chart.ChartXml

$ns = New-Object System.Xml.XmlNamespaceManager($chartXml.NameTable)
$ns.AddNamespace("c", "http://schemas.openxmlformats.org/drawingml/2006/chart")
$ns.AddNamespace("a", "http://schemas.openxmlformats.org/drawingml/2006/main")

$serNode = $chartXml.SelectSingleNode("//c:ser", $ns)
$points = $chartXml.SelectNodes("//c:ser/c:dPt", $ns)

# säkerställ datapoints finns
if ($points.Count -eq 0) {
    for ($i = 0; $i -lt $topRiskAdmins.Count; $i++) {

        $admin = $topRiskAdmins[$i]

        $dPt = $chartXml.CreateElement("c:dPt", $ns.LookupNamespace("c"))

        $idx = $chartXml.CreateElement("c:idx", $ns.LookupNamespace("c"))
        $idx.SetAttribute("val", $i)

        $spPr = $chartXml.CreateElement("c:spPr", $ns.LookupNamespace("c"))
        $solidFill = $chartXml.CreateElement("a:solidFill", $ns.LookupNamespace("a"))
        $srgbClr = $chartXml.CreateElement("a:srgbClr", $ns.LookupNamespace("a"))

        switch ($admin.AdminRiskLevel) {
            "Critical" { $srgbClr.SetAttribute("val", "C00000") } # red
            "High" { $srgbClr.SetAttribute("val", "FF8C00") } # orange
            "Medium" { $srgbClr.SetAttribute("val", "5B9BD5") } # blue
            default { $srgbClr.SetAttribute("val", "00B050") } # green
        }

        $solidFill.AppendChild($srgbClr) | Out-Null
        $spPr.AppendChild($solidFill) | Out-Null
        $dPt.AppendChild($idx) | Out-Null
        $dPt.AppendChild($spPr) | Out-Null

        $serNode.AppendChild($dPt) | Out-Null
    }
}




Close-ExcelPackage -ExcelPackage  $excel

Write-Host "✅ Export completed successfully: $exportPath" -ForegroundColor Green