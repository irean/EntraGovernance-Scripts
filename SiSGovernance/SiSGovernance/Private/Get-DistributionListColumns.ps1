function Get-DistributionListColumns {
    <#
    .SYNOPSIS
        Column order in every file the distribution list functions write. Any
        extra columns added by hand (e.g. structured scoping columns later on)
        are kept, after these.
    .NOTES
        Internal helper.
    #>

    @(
        'ObjectId',
        'DisplayName',
        'PrimarySmtpAddress',
        'OnPremisesSyncEnabled',
        'MemberCount',
        'Owners',
        'Include',
        'AccessPackageDisplayName',
        'AccessPackageDescription',
        'ScopingNotes',
        'AccessPackageId',
        'Status',
        'StatusMessage'
    )
}
