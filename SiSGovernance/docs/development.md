# Development

## Repository layout

```
SiSGovernance/                  folder in the EntraGovernance-Scripts repository
├── SiSGovernance/              the module - this folder is what's published
│   ├── SiSGovernance.psd1      manifest: version, dependencies, exported functions
│   ├── SiSGovernance.psm1      loads every file in Public\ and Private\
│   ├── Public\                 the functions you use - one per file
│   ├── Private\                the helpers behind them - one per file
│   └── en-US\                  about_SiSGovernance help topic
├── Tests/
│   └── SiSGovernance.Tests.ps1
├── docs/
├── PSScriptAnalyzerSettings.psd1
├── LICENSE
└── README.md
```

One function per file, named like the function. `FunctionsToExport` in the manifest decides what's visible after `Import-Module` — the functions in `Public\`. Everything in `Private\` stays inside the module.

A new function: add the file to `Public\` or `Private\`, and a public one to `FunctionsToExport` as well.

## Dependencies

Dependencies are declared in the manifest, not handled in code:

```powershell
RequiredModules = @('Microsoft.Graph.Authentication', 'ImportExcel')
```

- `Install-Module SiSGovernance` installs them from the PowerShell Gallery; `Import-Module SiSGovernance` loads them first, and fails clearly if one is missing.
- The module never installs or imports modules at runtime. If you start using a new module, add it to `RequiredModules` — don't install it from a function.
- When working from the repository (not an installed module), install them yourself once: `Install-Module Microsoft.Graph.Authentication, ImportExcel -Scope CurrentUser`.

## Tests

Run the commands below from the `SiSGovernance` folder.

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

- Pester 5. Windows ships with 3.4: `Install-Module Pester -Scope CurrentUser -SkipPublisherCheck`.
- Microsoft Graph is mocked — no tenant needed. Both dependencies must be installed: `ImportExcel` because the `Sync-SiSAccessPackage` tests write and read real Excel files in Pester's `TestDrive:`, and `Microsoft.Graph.Authentication` because the module tests import the real module, which requires it.
- The function tests run with `InModuleScope`, so private helpers can be called and mocked directly, and mocks of the Graph cmdlets apply to the module's own calls.
- A separate group checks the module as a whole: the manifest, the exported functions, one function per file, help at the top of every function, `-WhatIf`/`-Confirm` on every function that changes something, the declared output types, and that nothing prompts with `Read-Host`.
- Code coverage:

  ```powershell
  $config = New-PesterConfiguration
  $config.Run.Path = '.\Tests'
  $config.CodeCoverage.Enabled = $true
  $config.CodeCoverage.Path = '.\SiSGovernance\Public', '.\SiSGovernance\Private'
  Invoke-Pester -Configuration $config
  ```

## Script analysis

```powershell
Invoke-ScriptAnalyzer -Path .\SiSGovernance -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

Should return nothing. The settings file excludes these rules:

| Rule | Why |
|---|---|
| `PSAvoidUsingWriteHost` | Interactive, coloured output is intended |
| `PSUseSingularNouns` | Only triggers on private helpers |

`Add-` and `Remove-SiSAccessPackageAssignment` and `Add-` and `Remove-SiSAccessPackageResource` suppress `PSShouldProcess` in code, with a justification: they support `-WhatIf` and `-Confirm`, but the one confirmation per run is asked in the private helper they call, which the analyzer can't follow across files.

## Automatic checks (GitHub Actions)

`.github/workflows/sisgovernance.yml` in the repository root runs on every push and pull request that changes something under `SiSGovernance/`, and can be started by hand from the *Actions* tab:

- the Pester tests on Windows, in both PowerShell 7 and Windows PowerShell 5.1,
- code coverage (in PowerShell 7, target 75 %),
- PSScriptAnalyzer with the settings above — any finding fails the run.

Graph is mocked, so it needs no tenant, secrets or sign-in. The result shows on the commit, on pull requests, and in the *Tests* badge in the README. The test results (JUnit XML) and the coverage report (JaCoCo XML) are saved with each run.

## Output types

Every public function that returns objects declares it with `[OutputType()]`, and the objects carry a type name — `SiSGovernance.AssignmentResult`, `SiSGovernance.AccessPackage`, `SiSGovernance.ResourceChangeResult`, `SiSGovernance.ResourceRole`, `SiSGovernance.DistributionListRow`. Results come one object per user, package or row, so they can be piped on:

```powershell
$results = $upns | Add-SiSAccessPackageAssignment -AccessPackageId $apId -AssignmentPolicyId $policyId -Confirm:$false
$results | Where-Object Status -like 'Failed*'
```

## Function reference

The comment-based help in each function can be turned into Markdown pages with [platyPS](https://www.powershellgallery.com/packages/platyPS):

```powershell
Install-Module platyPS -Scope CurrentUser
Import-Module .\SiSGovernance\SiSGovernance.psd1 -Force
New-MarkdownHelp -Module SiSGovernance -OutputFolder .\docs\reference -Force
```

Re-run it when help changes, so the reference never drifts from the code.

The help ships as comment-based help in each function, plus the `about_SiSGovernance` topic (`Get-Help about_SiSGovernance`).

## Signing

For environments that only run signed scripts (`AllSigned`), sign every `.ps1`, `.psm1` and `.psd1` with an Authenticode code signing certificate before publishing:

```powershell
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select-Object -First 1
Get-ChildItem .\SiSGovernance -Include *.ps1, *.psm1, *.psd1 -Recurse |
    Set-AuthenticodeSignature -Certificate $cert -TimestampServer 'http://timestamp.digicert.com'
```

## Releasing a version

1. Raise `ModuleVersion` in the manifest (a published version can never be reused), and update `ReleaseNotes`. For a preview, set `Prerelease` in `PrivateData.PSData`; remove it for a final release.
2. Run the tests and the script analysis — or check that the latest GitHub Actions run is green.
3. Publish:
   ```powershell
   $key = Read-Host 'API key' -MaskInput
   Publish-PSResource -Path .\SiSGovernance -Repository PSGallery -ApiKey $key
   ```
4. Create a GitHub release with the same version tag (`v1.0.0-preview1`), marked as pre-release when it is one.
