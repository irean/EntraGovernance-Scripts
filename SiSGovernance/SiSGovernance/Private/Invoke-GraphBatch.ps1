function Invoke-GraphBatch {
    <#
    .SYNOPSIS
        Sends an array of requests to Microsoft Graph's $batch endpoint in
        chunks of up to 20 (Graph's per-batch limit), retrying individual 429
        (throttled) and 503/504 (transient) items with backoff, pacing between
        chunks, and returns the results correlated back to whatever key the
        caller supplied.
    .PARAMETER Requests
        Array of hashtables: @{ CorrelationKey = <anything>; Method = 'GET'|'POST'|'PATCH'; Url = '/relative/path'; Body = <optional hashtable>; Headers = <optional hashtable> }
        Headers is per request, e.g. @{ ConsistencyLevel = 'eventual' } for $count.
    .PARAMETER MaxRetries
        How many times to retry a 429/503/504 request before giving up and reporting
        it as failed. Default 5. Each retry waits per the response's Retry-After
        header if present, otherwise an exponential backoff capped at 60s.
    .PARAMETER DelayMs
        Fixed pause between chunks. Default 0 (no pause). Use it for writes - the
        write limit (3000 per 2.5 min per app + tenant, 18000 per 5 min for the
        whole tenant) is reached long before the read limit. Regardless of this
        value, the pause is raised automatically when Graph reports
        x-ms-throttle-limit-percentage >= 0.8.
    .OUTPUTS
        Array of PSCustomObject: CorrelationKey, Status (HTTP status, or 0 if the
        whole batch call failed without an answer), Body.
    .NOTES
        Internal helper. Url must be relative (no host) per Graph JSON batching
        rules. A $batch call is one HTTP round trip, but each sub-request is
        still evaluated against Graph's throttling individually and they run in
        parallel - batching does not exempt anything from rate limits, it only
        reduces connection overhead. entitlementManagement/assignmentRequests in
        particular is known to throttle heavily.

        When the whole $batch call fails:
          429/503/504 from Graph -> retried like any throttled request
          no answer, GET          -> retried
          no answer, POST/PATCH   -> NOT retried (it may already have run);
                                     reported with an "outcome unknown" message
    #>

    # One list on purpose (the caller gets it in one piece, also with 1 item)
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Requests,   # each: @{ CorrelationKey; Method; Url; Body (optional); Headers (optional) }

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 20)]
        [int]$BatchSize = 20,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60000)]
        [int]$DelayMs = 0
    )

    # Sends one sub-batch (<= 20 items) and returns, per item, its SourceItem
    # (so it can be resubmitted), CorrelationKey, Status, Headers, Body.
    $sendOneBatch = {
        param([array]$Items)

        $idToItem = @{}
        $batchRequests = [System.Collections.Generic.List[object]]::new()
        for ($j = 0; $j -lt $Items.Count; $j++) {
            $id = "$j"
            $idToItem[$id] = $Items[$j]

            $reqObj = @{
                id     = $id
                method = $Items[$j].Method
                url    = $Items[$j].Url
            }
            $reqHeaders = @{}
            if ($Items[$j].ContainsKey('Body') -and $null -ne $Items[$j].Body) {
                $reqHeaders['Content-Type'] = 'application/json'
                $reqObj.body = $Items[$j].Body
            }
            # Per-request headers, e.g. ConsistencyLevel: eventual for $count -
            # a header on the outer $batch call does NOT apply to the requests inside it
            if ($Items[$j].ContainsKey('Headers') -and $Items[$j].Headers) {
                foreach ($key in $Items[$j].Headers.Keys) {
                    $reqHeaders[$key] = $Items[$j].Headers[$key]
                }
            }
            if ($reqHeaders.Count -gt 0) {
                $reqObj.headers = $reqHeaders
            }
            $batchRequests.Add($reqObj)
        }

        $payload = @{ requests = @($batchRequests) } | ConvertTo-Json -Depth 10

        $out = [System.Collections.Generic.List[object]]::new()
        try {
            $batchResult = Invoke-MgGraphRequest -Method POST `
                -Uri 'https://graph.microsoft.com/v1.0/$batch' `
                -Body $payload `
                -ContentType 'application/json' `
                -ErrorAction Stop
        }
        catch {
            # The $batch call itself failed. If Graph answered with 429/503/504
            # the batch was rejected before anything ran, so that status is
            # passed on and the normal retry picks it up. Without an HTTP status
            # (network error, timeout) we don't know what ran - Status 0.
            $outerStatus = 0
            $outerRetryAfter = $null
            $response = $_.Exception.Response
            if ($response) {
                try { $outerStatus = [int]$response.StatusCode }
                catch { Write-Verbose "No HTTP status on the failed batch call - treated as 'no answer'." }
                try {
                    if ($response.Headers.RetryAfter.Delta) {
                        $outerRetryAfter = [int][Math]::Ceiling($response.Headers.RetryAfter.Delta.TotalSeconds)
                    }
                }
                catch { Write-Verbose "No Retry-After header on the failed batch call - default backoff is used." }
            }
            $errorMessage = $_.Exception.Message
            foreach ($id in $idToItem.Keys) {
                $out.Add([PSCustomObject]@{
                        SourceItem     = $idToItem[$id]
                        CorrelationKey = $idToItem[$id].CorrelationKey
                        Status         = $outerStatus
                        Headers        = $(if ($null -ne $outerRetryAfter) { @{ 'Retry-After' = "$outerRetryAfter" } } else { @{} })
                        Body           = @{ error = @{ message = $errorMessage } }
                    })
            }
            return ,$out
        }

        foreach ($resp in $batchResult.responses) {
            $item = $idToItem["$($resp.id)"]
            $out.Add([PSCustomObject]@{
                    SourceItem     = $item
                    CorrelationKey = $item.CorrelationKey
                    Status         = $resp.status
                    Headers        = $(if ($resp.headers) { $resp.headers } else { @{} })
                    Body           = $resp.body
                })
        }
        return ,$out
    }

    # 429 = throttled, 503/504 = transient service errors. All three are
    # worth another try instead of being reported as Failed.
    # Status 0 (the whole $batch call failed without an answer) is only
    # retried for GET: a POST/PATCH may already have gone through, and
    # sending it again blind could e.g. create a second access package.
    $isRetryable = {
        param($r)
        ($r.Status -in 429, 503, 504) -or ($r.Status -eq 0 -and $r.SourceItem.Method -eq 'GET')
    }

    $allResponses = [System.Collections.Generic.List[object]]::new()

    $chunks = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Requests.Count; $i += $BatchSize) {
        $endIndex = [Math]::Min($i + $BatchSize - 1, $Requests.Count - 1)
        $chunks.Add(@($Requests[$i..$endIndex]))
    }

    # Progress bar for the whole call, details with -Verbose
    $progress = @{ Id = 1; Activity = "Microsoft Graph batch ($($Requests.Count) requests)" }
    $chunkNum = 0
    foreach ($chunk in $chunks) {
        $chunkNum++
        Write-Progress @progress -Status "Batch $chunkNum of $($chunks.Count)" -PercentComplete ([int](($chunkNum - 1) / $chunks.Count * 100))
        Write-Verbose "Batch $chunkNum/$($chunks.Count) ($($chunk.Count) requests)"

        $pending = $chunk
        $attempt = 0
        $chunkDone = [System.Collections.Generic.List[object]]::new()

        while ($pending.Count -gt 0) {
            $results = & $sendOneBatch $pending

            $throttled = @($results | Where-Object { & $isRetryable $_ })
            foreach ($r in $results) {
                if (-not (& $isRetryable $r)) { $chunkDone.Add($r) }
            }

            if ($throttled.Count -eq 0) { break }

            if ($attempt -ge $MaxRetries) {
                Write-Warning "Still throttled/unavailable after $MaxRetries retries on $($throttled.Count) request(s) - giving up, reporting them as Failed. Re-run later to finish."
                foreach ($r in $throttled) { $chunkDone.Add($r) }
                break
            }

            $retryAfterValues = @($throttled | ForEach-Object { $_.Headers.'Retry-After' } | Where-Object { $_ })
            if ($retryAfterValues.Count -gt 0) {
                $waitSeconds = ($retryAfterValues | ForEach-Object { [int]$_ } | Sort-Object -Descending | Select-Object -First 1)
            }
            else {
                $waitSeconds = [Math]::Min(5 * [Math]::Pow(2, $attempt), 60)
            }

            $statusList = ($throttled.Status | Sort-Object -Unique | ForEach-Object { if ($_ -eq 0) { 'no response' } else { $_ } }) -join '/'
            $waitText = "Throttled/unavailable ($statusList) on $($throttled.Count) request(s) - waiting $waitSeconds s before retry $($attempt + 1)/$MaxRetries"
            Write-Progress @progress -Status "Batch $chunkNum of $($chunks.Count) - $waitText" -PercentComplete ([int](($chunkNum - 1) / $chunks.Count * 100))
            Write-Verbose $waitText
            Start-Sleep -Seconds $waitSeconds

            $pending = @($throttled | ForEach-Object { $_.SourceItem })
            $attempt++
        }

        # A write that got no answer at all: make the message say so, so it's
        # not mistaken for a normal rejection. Re-running reconciles it
        # (AlreadyAssigned / Linked) instead of duplicating.
        foreach ($r in $chunkDone) {
            if ($r.Status -eq 0 -and $r.SourceItem.Method -ne 'GET') {
                $r.Body = @{ error = @{ message = "Batch call failed, outcome unknown - re-run to reconcile: $($r.Body.error.message)" } }
            }
            $allResponses.Add($r)
        }

        # --- Pacing before the next chunk -------------------------------------
        if ($chunkNum -lt $chunks.Count) {
            $pauseMs = $DelayMs

            # Graph reports how close we are to the limit (0.8 = 80%) on normal
            # responses. If it's there, slow down before we get 429s instead of after.
            # Best effort: not every service/response includes the header.
            $limitValues = @($chunkDone | ForEach-Object {
                    $v = $_.Headers.'x-ms-throttle-limit-percentage'
                    if ($v) { [double]::Parse("$v", [System.Globalization.CultureInfo]::InvariantCulture) }
                })
            if ($limitValues.Count -gt 0) {
                $maxLimit = ($limitValues | Measure-Object -Maximum).Maximum
                if ($maxLimit -ge 0.8) {
                    # 0.8 -> 1s, 0.9 -> 2s, 1.0 -> 3s ... capped at 10s
                    $adaptiveMs = [int]([Math]::Min([Math]::Ceiling([Math]::Round(($maxLimit - 0.7) * 10, 6)), 10) * 1000)
                    if ($adaptiveMs -gt $pauseMs) {
                        Write-Verbose "At $([int]($maxLimit * 100))% of the throttling limit - slowing down to $($adaptiveMs / 1000) s between batches"
                        $pauseMs = $adaptiveMs
                    }
                }
            }

            if ($pauseMs -gt 0) { Start-Sleep -Milliseconds $pauseMs }
        }
    }

    Write-Progress @progress -Completed

    $output = foreach ($r in $allResponses) {
        [PSCustomObject]@{
            CorrelationKey = $r.CorrelationKey
            Status         = $r.Status
            Body           = $r.Body
        }
    }
    return ,@($output)
}
