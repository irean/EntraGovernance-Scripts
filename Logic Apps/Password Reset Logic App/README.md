# Password Reset Logic App – Deployment Guide

Automated deployment of an Azure Logic App that handles password resets for new hires via Entra ID Lifecycle Workflows.

---

## Overview

This solution deploys a Logic App that integrates with Entra ID Lifecycle Workflows as a custom task extension. When triggered by a Lifecycle Workflow, the Logic App:

- Generates a temporary password and resets the user's account
- Sends the password to the user's manager via email
- Waits 5 days and checks if the user has logged in and changed their password
- If not: resets to a new unknown password and notifies the manager to contact the service desk

The same Logic App can be reused for offboarding workflows — the `Is Onboarding Workflow` condition controls which branch executes.

---

## Prerequisites

### Azure
- An existing **Resource Group** where the Logic App will be deployed
- Contributor access to that Resource Group

### PowerShell Modules
The following modules must be available. The script will install them automatically if missing:
- `Az.Accounts`
- `Az.Resources`
- `Az.LogicApp`
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Applications`

### Mail sender
A mailbox must exist in Exchange Online for the sender address you provide (e.g. `governance@yourcompany.com`). The Logic App's managed identity will be granted `Mail.Send` on behalf of this mailbox.

### Entra ID Lifecycle Workflow
You need the **workflow ID(s)** of the Lifecycle Workflow(s) that will call this Logic App. These are found in:
**Entra ID Portal → Identity Governance → Lifecycle Workflows → your workflow → Properties**

---

## Files

| File | Description |
|---|---|
| `Deploy-PasswordResetLogicApp.ps1` | Main deployment script containing all functions |
| `LogicApp.json` | Logic App workflow definition template |

---

## Usage

### 1. Load the functions

```powershell
. .\Deploy-PasswordResetLogicApp.ps1
```

### 2. Run the deployment

**Interactive login:**
```powershell
Deploy-PasswordResetLogicApp `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ResourceGroup "rg-entra-governance-prod" `
    -LogicAppName "la-Password-Reset" `
    -Location "swedencentral" `
    -MailSender "governance@contoso.com" `
    -OnboardingWorkflowIds @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
```

**Service Principal with certificate:**
```powershell
Deploy-PasswordResetLogicApp `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ResourceGroup "rg-entra-governance-prod" `
    -LogicAppName "la-Password-Reset" `
    -Location "swedencentral" `
    -MailSender "governance@contoso.com" `
    -OnboardingWorkflowIds @("xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx") `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -CertificateThumbprint "ABC123..." `
    -AppId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

**Multiple onboarding workflow IDs:**
```powershell
-OnboardingWorkflowIds @(
    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
)
```

> If you need more than 2 workflow IDs, add additional `equals` blocks with `ONBOARDING_WORKFLOW_ID_3` etc. in `LogicApp.json` before deploying.

---

## What the script does

1. Authenticates against Azure (interactive or Service Principal)
2. Reads and validates `LogicApp.json`
3. Replaces tenant-specific placeholders:
   - `governance@epicalgroup.com` → your `MailSender`
   - `ONBOARDING_WORKFLOW_ID_1`, `ONBOARDING_WORKFLOW_ID_2` → your workflow IDs
4. Creates or updates the Logic App via ARM REST API
5. Enables System-assigned Managed Identity on the Logic App
6. Assigns the following Microsoft Graph permissions to the Managed Identity:
   - `Mail.Send`
   - `UserAuthenticationMethod.ReadWrite.All`
   - `AuditLog.Read.All`
   - `User.ReadWrite.All`
   - `User.RevokeSessions.All`

---

## After deployment

The script outputs the Logic App's **Principal ID** at the end. You will need this to register the Logic App as a custom task extension in Entra ID Lifecycle Workflows:

1. Go to **Entra ID Portal → Identity Governance → Lifecycle Workflows**
2. Open your workflow → **Tasks**
3. Add a custom extension task and point it to this Logic App
4. Set the extension to **Sequential** mode so the workflow waits for the Logic App to complete

---

## Required Graph permissions

| Permission | Purpose |
|---|---|
| `Mail.Send` | Send email to manager |
| `UserAuthenticationMethod.ReadWrite.All` | Reset authentication methods |
| `AuditLog.Read.All` | Read sign-in activity (`signInActivity`) — requires Entra ID P1/P2 |
| `User.ReadWrite.All` | Reset password via `passwordProfile` |
| `User.RevokeSessions.All` | Revoke active sessions (offboarding) |

> `AuditLog.Read.All` requires an **Entra ID P1 or P2** license to read `signInActivity`. Without it, the 5-day sign-in check will not work correctly.

---

## Reusing for offboarding

The Logic App's `Is Onboarding Workflow` condition checks the incoming workflow ID against the list of onboarding workflow IDs. If the calling workflow is **not** in that list, the False branch executes — this is where offboarding logic goes.

To extend for offboarding, add steps in the False branch of `Is Onboarding Workflow` in the Logic App designer.

---

## Troubleshooting

| Error | Likely cause | Fix |
|---|---|---|
| `Forbidden` on password reset | Missing `User.ReadWrite.All` or permissions not propagated | Wait a few minutes and retry |
| `InvalidAuthenticationToken` | Managed Identity not enabled or authentication not set on HTTP step | Check Identity is enabled on the Logic App |
| `Managed Identity not visible after propagation` | ARM hasn't propagated yet | Run the script again — it will update the existing Logic App |
| `ONBOARDING_WORKFLOW_ID_1` visible in designer | Workflow ID was not replaced | Verify you passed the correct ID and that `LogicApp.json` has the placeholder |
| `AuditLog` returns no sign-in data | Missing Entra ID P1/P2 license | Assign P1/P2 or adjust the condition logic |