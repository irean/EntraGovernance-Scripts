# Entra Manager Flag Sync

A Consumption Logic App that keeps two Entra ID directory extension attributes
in sync for every employee/subcontractor: whether they are a manager, and
whether their team is national or international.

Runs on a daily recurrence. For each in-scope user it looks at their direct
reports and:

- If they have at least one direct report who is an Employee or Subcontractor,
  it sets the "is manager" attribute to `true` and the "management scope"
  attribute to `International` (direct reports span more than one country) or
  `National` (all in one country).
- Otherwise, if the "is manager" attribute was previously `true`, it clears
  both attributes.

Deployment is pushed with Azure PowerShell — no manual edits in the Azure
Portal designer required. The template is authored in Bicep (`main.bicep`),
with the equivalent plain ARM JSON (`azuredeploy.json`) kept alongside it for
any tooling that only accepts JSON. Both deploy to the exact same resource —
Bicep is just easier to read and edit, and its tooling (the VS Code
extension) catches template mistakes before you deploy.

## Repository contents

| File | Purpose |
|---|---|
| `main.bicep` | Bicep template (recommended): the `Microsoft.Logic/workflows` resource, its identity assignment, and parameters. Loads the workflow definition from `workflow.definition.json`. |
| `workflow.definition.json` | The Logic App's workflow definition (triggers/actions) — the part you'd also see in the Logic App Designer's code view. Used by `main.bicep` via `loadJsonContent()`. |
| `azuredeploy.json` | Equivalent plain ARM JSON template, self-contained (the workflow definition is inlined, no separate file needed). Use this if your pipeline/tooling doesn't support Bicep. |
| `azuredeploy.parameters.example.json` | Example parameter file with placeholders. Works for deploying either `main.bicep` or `azuredeploy.json` — same parameter names. Copy it, fill in real values, keep the copy out of version control if it contains anything environment-specific you don't want public. |
| `Deploy-LogicApp.ps1` | Wraps `New-AzResourceGroupDeployment` to push the template, with `-WhatIf` support. Defaults to `main.bicep`; pass `-TemplateFile ./azuredeploy.json` to use the JSON version instead. |
| `.gitignore` | Excludes any filled-in `azuredeploy.parameters.*.json` copy (keeping the `.example.json` one tracked), so real environment values don't end up in version control. |

## Prerequisites

- An Azure resource group to deploy into.
- A user-assigned managed identity that will be assigned to the Logic App and
  used for every Microsoft Graph call.
- That identity needs Microsoft Graph **application** permissions, admin-consented:
  read access to users and their direct reports (e.g. `User.Read.All`), and
  write access to update the two extension attributes (e.g.
  `User.ReadWrite.All`, or a narrower Graph permission scoped to your custom
  extension attributes).
- The two directory extension attributes themselves must already exist in
  your tenant, created against an Entra app registration. This template
  references them by name — it does not create them.
- Azure PowerShell (`Az.Resources`, `Az.Accounts`).
- Bicep CLI, if you're deploying `main.bicep` (the recommended path). Without
  it, `New-AzResourceGroupDeployment` fails with "Cannot find Bicep. Please
  add Bicep to your PATH". Install it with:

  ```powershell
  winget install -e --id Microsoft.Bicep
  ```

  (or `az bicep install` if you already have Azure CLI). Close and reopen
  your PowerShell window afterwards so it picks up the updated PATH. If you'd
  rather not install it, deploy `azuredeploy.json` instead — see
  [Deploying](#deploying) below.

## Configuration

All environment-specific values are deployment parameters — nothing is
hardcoded in the template.

| Parameter | Description | Default |
|---|---|---|
| `logicAppName` | Name of the Logic App resource. | — |
| `location` | Azure region. | resource group's region |
| `managedIdentityResourceId` | Full resource ID of the user-assigned managed identity to assign to the Logic App and use for Graph calls. | — |
| `isManagerAttributeName` | Full name of the "is manager" directory extension attribute, e.g. `extension_<extension-app-id-without-dashes>_idg_isManager`. | — |
| `managementScopeAttributeName` | Full name of the "management scope" directory extension attribute, e.g. `extension_<extension-app-id-without-dashes>_idg_managementScope`. | — |
| `graphBaseUrl` / `graphAudience` | Microsoft Graph base URL / token audience. Only change for a sovereign cloud. | `https://graph.microsoft.com` |
| `includedEmployeeTypes` | `employeeType` values that count as a real direct report. | `["Employee", "Subcontractor"]` |
| `recurrenceInterval` / `recurrenceFrequency` / `recurrenceHours` | The trigger schedule. | every 1 day, at 02:00 |

## Deploying

**1. Copy the example parameters file — don't edit it in place.**

`azuredeploy.parameters.example.json` is a template with placeholders and
stays that way in the repo, for the next person who needs it. Make your own
copy and fill in real values there instead:

```powershell
cp azuredeploy.parameters.example.json azuredeploy.parameters.prod.json
# now edit azuredeploy.parameters.prod.json with your real values
```

Your filled-in copy will contain real resource IDs (subscription, managed
identity, etc.) — keep it out of version control. This repo's `.gitignore`
already excludes any `azuredeploy.parameters.*.json` file except the example
one, so as long as you name your copy something other than
`azuredeploy.parameters.example.json`, git won't pick it up.

**2. Install prerequisites and sign in:**

```powershell
Install-Module Az.Resources -Scope CurrentUser   # if not already installed
Connect-AzAccount
```

**3. Review, then deploy:**

```powershell
./Deploy-LogicApp.ps1 `
    -ResourceGroupName "<your-resource-group>" `
    -ParameterFile "./azuredeploy.parameters.prod.json" `
    -WhatIf                                        # review first

./Deploy-LogicApp.ps1 `
    -ResourceGroupName "<your-resource-group>" `
    -ParameterFile "./azuredeploy.parameters.prod.json"   # deploy
```

Re-running the same command against an existing Logic App updates it in
place.

## If you need to change the workflow logic

Edit `workflow.definition.json` (the triggers/actions) — it's plain Logic App
definition JSON, the same thing you'd edit in the Designer's code view. If
you keep `azuredeploy.json` around too, copy the same change into its
`properties.definition` block, since that file has its own inlined copy
rather than loading the shared one. Treat `main.bicep` +
`workflow.definition.json` as the source of truth; regenerate
`azuredeploy.json` from it if it drifts (`bicep build main.bicep --outfile azuredeploy.json`
gets you close, though the output needs the parameter `metadata.description`
blocks added back in by hand since `bicep build` doesn't emit those).

## Known limitations

- The recurrence trigger's `interval`, `frequency`, and `hours` are driven by
  workflow parameters. This has deployed successfully end-to-end (via
  `main.bicep`); the actual fire time is still worth a quick check in the
  Logic App's run history after its first scheduled run.
- `$connections` is declared as an empty object in the workflow definition.
  This workflow only makes plain HTTP calls (no API connections), so it's
  always `{}` and isn't exposed as a deployment parameter — it's only there
  because Logic Apps requires the parameter to be declared if a value is
  supplied for it.