function Test-IsGuid {
    <#
    .SYNOPSIS
        True if the value is a GUID. Used before any id from a file or a
        parameter is put into a Graph URL.
    #>

    param([string]$Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse("$Value".Trim(), [ref]$parsed)
}
