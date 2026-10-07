# Assignments

`Add-SiSAccessPackageAssignment` assigns users to an access package, `Remove-SiSAccessPackageAssignment` removes their assignments. Both need the package's **assignment policy** id — the policy has to exist first.

## Where the users come from

Pick one:

```powershell
# A few UPNs
Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId `
    -UserPrincipalName 'anna@contoso.com', 'erik@contoso.com'

# The pipeline - a variable, a file, any command that outputs UPNs
$users | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId
Import-Excel .\users.xlsx | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId

# An Excel file with a 'userPrincipalName' column
Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId -ExcelPath .\users.xlsx

# A Graph filter
Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId `
    -Filter "userType eq 'Member' and department eq 'Sales'"
```

From the pipeline, UPN strings and objects with a `userPrincipalName` property both work. Everything piped in is collected first: one preview, one confirmation, one batch run. Duplicates are removed, so a user piped in twice gets one request.

### Check a filter before you use it

`Get-SiSGraphUser` needs `User.Read.All` on your Graph connection.

```powershell
Get-SiSGraphUser -Filter "userType eq 'Member' and department eq 'Sales'"

# Which values does an attribute actually have? (Filters are exact-match.)
Get-SiSGraphUser -Filter "userType eq 'Member'" -Select 'department' |
    Select-Object -ExpandProperty department -Unique
```

## Parameters

| Parameter | |
|---|---|
| `-WhatIf` | Resolve and show the users, change nothing |
| `-Confirm:$false` | Submit without asking — for unattended runs |
| `-MaxUsers` | Stop if the run would touch more users than this. Default 500. |
| `-OutputPath` | Folder for the Excel report. Without it, a folder dialog opens at the start. |
| `-SkipReport` | No Excel report and no folder to choose — the results are still returned |
| `-DelayMs` | Pause between batches. Default 1000 ms — see [How it works](how-it-works.md) |
| `-BatchSize` | Requests per batch, max 20 |

## Add vs Remove

They work differently because Graph does:

- **Add** sends a request per user straight away. A user who already has the assignment is rejected by Graph and reported as `AlreadyAssigned` — no extra lookup first.
- **Remove** needs the id of the user's existing assignment. All current (delivered) assignments of the package are read once first; users with nothing to remove are reported as `NotAssigned` and never sent.

## Results

Both functions return one object per user (`UserPrincipalName`, `DisplayName`, `ObjectId`, `Status`, `Error`), so the results can be piped on:

```powershell
$results = $upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId
$results | Where-Object Status -like 'Failed*' | Export-Excel .\failed.xlsx
```

| `Status` | Meaning |
|---|---|
| `Submitted` | The request was sent to Graph |
| `AlreadyAssigned` | The user already had the assignment (add) |
| `NotAssigned` | The user had nothing to remove (remove) |
| `OpenRequestExists` | A request for this user and package is already pending |
| `Failed - User not found` | The UPN doesn't exist in the tenant |
| `Failed` | See the `Error` column |
| `Preview - Add` / `Preview - Remove` | `-WhatIf`: nothing was sent |

The full list is printed and exported to `ADD-<package>-<timestamp>.xlsx` or `REMOVE-<package>-<timestamp>.xlsx` — so a second run never overwrites the first. The folder is chosen before anything else happens: with `-OutputPath`, or in the dialog that opens first. A summary per status comes last, with failures grouped by error message.

`Submitted` means Entitlement Management has accepted the request — it then processes it asynchronously. Check the package's assignments in the portal if you need to confirm delivery.
