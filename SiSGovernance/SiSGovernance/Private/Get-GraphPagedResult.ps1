function Get-GraphPagedResult {
    <#
    .SYNOPSIS
        GET from Microsoft Graph, following @odata.nextLink, and output every item
        as a PSCustomObject.
    .DESCRIPTION
        For a collection only the items in 'value' are output - an empty result
        outputs nothing. Anything else (a single object) is output as is.
        Stops after -MaxPages pages, with a warning if there were more.
    .PARAMETER Uri
        Full Graph URL, including any $filter/$select/$expand.
    .PARAMETER Eventual
        Sends ConsistencyLevel: eventual - needed for $count and advanced filters.
    .PARAMETER MaxPages
        Safety cap on how many pages are read. Default 1000.
    .NOTES
        Internal helper.
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [switch]$Eventual,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100000)]
        [int]$MaxPages = 1000
    )

    $headers = @{ Accept = 'application/json' }
    if ($Eventual) { $headers['ConsistencyLevel'] = 'eventual' }

    $nextUri = $Uri
    $pages = 0
    do {
        # -OutputType PSObject: Graph's JSON as PSCustomObjects directly, with
        # arrays kept as arrays - no hashtable conversion of our own
        $result = Invoke-MgGraphRequest -Method GET -Uri $nextUri -Headers $headers -OutputType PSObject
        $pages++

        if ($null -eq $result) { break }
        if ($result.PSObject.Properties.Name -contains 'value') {
            # A collection: only the items. An empty collection gives nothing -
            # never the response itself, which would look like one result.
            $result.value
        }
        else {
            # A single object (e.g. GET /catalogs/{id})
            $result
        }
        $nextUri = $result.'@odata.nextLink'
    } while ($nextUri -and $pages -lt $MaxPages)

    if ($nextUri) {
        Write-Warning "Stopped after $MaxPages page(s) - there are more results than were read. Narrow the query or raise -MaxPages."
    }
}
