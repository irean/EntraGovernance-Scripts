function Remove-SiSAccessPackageAssignment {
    <#
    .SYNOPSIS
        Removes one or more users' assignments from an Access Package, sourcing the users from an Excel file, a Graph $filter query, a
        list of UPNs or the pipeline - all through the same flow.

    .DESCRIPTION
        Validates the Access Package and Assignment Policy, resolves the target
        users (batching UPN -> id lookups), shows a preview, asks for confirmation
        once, and
        submits the requests via Graph JSON batching (up to 20 per HTTP call), with
        retry and pacing.

        adminRemove needs the existing assignment's own id, so current assignments
        are looked up once (state Delivered) before submitting. Users with nothing
        to remove are reported as NotAssigned and never submitted.
        A request already pending for a user is reported as OpenRequestExists.

        The folder for the Excel report is chosen first - with -OutputPath, or in
        a dialog - so the run never stops halfway to ask. -SkipReport skips the
        report. The results are always returned, one object per user.

    .PARAMETER AccessPackageId
        The ObjectId of the Access Package to target.

    .PARAMETER AssignmentPolicyId
        The ObjectId of the Assignment Policy within the Access Package.

    .PARAMETER ExcelPath
        Path to an Excel file with a 'userPrincipalName' column. (ParameterSet 'Excel')

    .PARAMETER Filter
        An OData filter expression evaluated against /v1.0/users. (ParameterSet 'Filter')

    .PARAMETER UserPrincipalName
        One or more UPNs directly. (ParameterSet 'Users', default)
        Also accepts pipeline input: UPN strings, or objects with a userPrincipalName
        property. Everything piped in is collected first and run as one batch, with
        one preview and one confirmation. Duplicates are removed.

    .PARAMETER MaxUsers
        Safety cap on how many users a single run may touch. Default 500.

    .PARAMETER WhatIf
        Resolves and displays the target users, then stops without submitting
        anything. Returns one result per user, with Status 'Preview - <action>'.

    .PARAMETER Confirm
        Asks before submitting (the default). -Confirm:$false submits without
        asking - for unattended runs, e.g. in an Azure Function.

    .PARAMETER SkipReport
        No Excel report - and no folder to choose. The results are still returned
        as objects.

    .PARAMETER OutputPath
        Folder for the Excel report. Without it, a folder dialog opens at the
        start of the run (Windows).

    .PARAMETER BatchSize
        Requests per Graph $batch call. Default and max 20 (Graph's own limit).

    .PARAMETER DelayMs
        Pause between batch calls when submitting the requests. Default 1000 ms,
        which keeps a run at roughly half of Graph's write limit for the app
        (3000 per 2.5 min). Raised automatically if Graph reports it's close to the limit.

    .EXAMPLE
        # Excel-based removal, with the report in a set folder
        Remove-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $polId `
            -ExcelPath "C:\users.xlsx" -OutputPath "C:\Reports"

    .EXAMPLE
        # From the pipeline
        $users | Remove-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $polId

    .OUTPUTS
        SiSGovernance.AssignmentResult, one per user: UserPrincipalName, DisplayName,
        ObjectId, Status (Submitted / NotAssigned / OpenRequestExists / Failed /
        Failed - User not found / Preview - Remove), Error.

    .NOTES
        Required scopes: User.Read.All, EntitlementManagement.ReadWrite.All
        Least privileged role: Access package assignment manager on the catalog (via PIM)
    #>

    [OutputType('SiSGovernance.AssignmentResult')]
    # The confirmation is asked once for the whole run, in Invoke-AccessPackageAssignmentRequest -
    # -WhatIf and -Confirm reach it through the preference variables
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is called in Invoke-AccessPackageAssignmentRequest, which this function calls')]
    [CmdletBinding(DefaultParameterSetName = 'Users', SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [guid]$AccessPackageId,

        [Parameter(Mandatory = $true)]
        [guid]$AssignmentPolicyId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Excel')]
        [string]$ExcelPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Filter')]
        [string]$Filter,

        [Parameter(Mandatory = $true, ParameterSetName = 'Users', ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [string[]]$UserPrincipalName,

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
        $collectedUpns = [System.Collections.Generic.List[string]]::new()
    }

    process {
        # Pipeline input arrives one item at a time - collect everything first,
        # so the preview, -MaxUsers, the confirmation and the batching happen once
        if ($PSCmdlet.ParameterSetName -ne 'Users') { return }
        foreach ($upn in $UserPrincipalName) {
            if ("$upn".Trim()) { $collectedUpns.Add("$upn".Trim()) }
        }
    }

    end {
        $params = @{}
        foreach ($key in $PSBoundParameters.Keys) { $params[$key] = $PSBoundParameters[$key] }
        $params['AccessPackageId'] = $AccessPackageId.ToString('D')
        $params['AssignmentPolicyId'] = $AssignmentPolicyId.ToString('D')

        if ($PSCmdlet.ParameterSetName -eq 'Users') {
            if ($collectedUpns.Count -eq 0) {
                Write-Warning "No users received. Nothing to do."
                return
            }
            $params['UserPrincipalName'] = @($collectedUpns)
        }

        Invoke-AccessPackageAssignmentRequest @params -AdminRemove
    }
}
