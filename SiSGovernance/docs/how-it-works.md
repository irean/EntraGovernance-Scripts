# How it works

## Read, preview, confirm, change

Every function that changes something follows the same order:

1. **Read** — resolve the catalog, packages, users and resources. Nothing is changed.
2. **Validate** — and report every problem at once, not one per run.
3. **Preview** — show what will happen. `-WhatIf` stops here.
4. **Confirm** — PowerShell's standard `[Y] Yes / [N] No` question, once per run, also when many objects are piped in. `-Confirm:$false` skips it.
5. **Change** — and report a status per object.

`-WhatIf` and `-Confirm` work the same way in every function that changes something, as in any Microsoft module.

Safety caps stop runs that are bigger than expected: `-MaxUsers` (default 500) for assignments, `-MaxPackages` (default 200) for `Sync-SiSAccessPackage`.

## Errors

A problem that stops the whole run — not connected, a missing scope, a catalog or package that doesn't exist, a file that can't be read, invalid rows, a run over the safety cap — is a normal PowerShell error. `$?` is `$false`, and with `-ErrorAction Stop` (or `$ErrorActionPreference = 'Stop'`, as in most Azure Functions) it can be caught with `try`/`catch`:

```powershell
try {
    Sync-SiSAccessPackage -ExcelPath $file -CatalogName "Distribution Lists" -OutputPath $folder -Confirm:$false -ErrorAction Stop
}
catch {
    # e.g. 2 row(s) failed validation - nothing was created or changed
    Write-Error $_
}
```

A problem with a single object — one user, one package — doesn't stop the others. It's reported as `Failed` with the reason in that object's result, and in the results file.

## Re-running is safe

Every function recognises work that's already done and reports it instead of failing or duplicating:

| Function | Already done shows as |
|---|---|
| `Add-SiSAccessPackageAssignment` | `AlreadyAssigned` |
| `Remove-SiSAccessPackageAssignment` | `NotAssigned` |
| `Add-SiSAccessPackageResource` | `AlreadyAdded` |
| `Remove-SiSAccessPackageResource` | `NotOnPackage` |
| `Sync-SiSAccessPackage` | `Linked`, `Unchanged` |
| `New-SiSAccessPackage` | stops: name already exists in the catalog |

If a run is interrupted, or some requests fail after all retries, run it again.

## Batching

Calls that touch many objects use Microsoft Graph JSON batching: up to 20 requests per HTTP call.

Batching saves round trips, **not quota**. Each request inside a batch still counts against Graph's throttling limits, and the 20 run in parallel. The write limits are the ones you hit first — roughly 3,000 writes per 2.5 minutes per app and tenant, and 18,000 per 5 minutes for the whole tenant, shared with every other app and admin.

## Retry

| Situation | What happens |
|---|---|
| A request gets 429 (throttled), 503 or 504 | Retried — after `Retry-After` if Graph sends it, otherwise with exponential backoff (max 60 s). Up to 5 retries. |
| The whole batch call gets 429 / 503 / 504 | Retried the same way |
| The whole batch call gets no answer (network error, timeout) — **reads** | Retried |
| The whole batch call gets no answer — **writes** | **Not** retried: the write may already have gone through. Reported as *outcome unknown — re-run to reconcile*. Re-running is safe (see above). |

## Pacing

Writes pause between batches: `-DelayMs`, default 1000 ms. That keeps a run at roughly half the write limit for one app, so the rest of the tenant isn't starved. Reads aren't paced.

If Graph reports that you're close to the limit (`x-ms-throttle-limit-percentage` ≥ 80 %), the pause is raised automatically — from 1 s up to 10 s — to slow down **before** the 429s rather than after.

For a small run, `-DelayMs 0` turns the fixed pause off.

## Reports and files

| Function | Writes |
|---|---|
| `Add-` / `Remove-SiSAccessPackageAssignment` | `ADD-` / `REMOVE-<package>-<timestamp>.xlsx` (skip with `-SkipReport`) |
| `Export-SiSDistributionList` | `DistributionLists-<timestamp>.xlsx` |
| `Sync-SiSAccessPackage` | `AccessPackages-` or `Preview-<catalog>-<timestamp>.xlsx`, and with `-BicepOutput` a `.bicepparam` |

Every file name has a timestamp, so nothing is overwritten — input files included.

Every function that writes a file asks for the folder before it starts, or takes it from `-OutputPath` — so a run never stops halfway to ask.

Names and addresses in the files come from Entra, where anyone who can rename a group or a user decides the text. So text is always written as text: never as a formula (text that starts with `=`), never as a clickable link.

## Running without any input

| Function | Add |
|---|---|
| `Sync-SiSAccessPackage` | `-OutputPath` and `-Confirm:$false` |
| `Export-SiSDistributionList` | `-OutputPath` |
| `Add-` / `Remove-SiSAccessPackageAssignment` | `-OutputPath` (or `-SkipReport`) and `-Confirm:$false` |
| `New-SiSAccessPackage`, `Add-` / `Remove-SiSAccessPackageResource` | `-Confirm:$false` |

## Results

Every function returns one object per user, package or row, with a `Status` (and an `Error` when it failed), so results can be piped on, filtered or exported:

```powershell
$results = $upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId -SkipReport -Confirm:$false
$results | Where-Object Status -like 'Failed*'
```

`Export-SiSDistributionList` and `Sync-SiSAccessPackage` return the same rows as in their Excel file — `Sync-SiSAccessPackage` with `AccessPackageId`, `Status` and `StatusMessage` per row.

## Progress and details

Batched calls show a progress bar. `-Verbose` shows every batch, every retry and every slow-down. When requests are still throttled after all retries, there's a warning, and they're reported as `Failed` — run again later to finish.
