# Password Reset Logic App

Deploys an Azure Logic App for automated password resets, wired into Entra ID Lifecycle Workflows as a custom task extension.

Built to handle the part Microsoft's documentation skips — the actual deployment, managed identity setup, and Graph permissions, all in one script.

Related blog posts at [agderinthe.cloud](https://agderinthe.cloud/author/sandra/)

---

## What it does

When triggered by a Lifecycle Workflow on the employee's hire date:

- Generates a temporary password and resets the account
- Sends the password to the manager via email
- Waits 5 days and checks whether the user has logged in **and** changed their password
- If not: resets to a new unknown password and notifies the manager to contact the service desk

The same Logic App handles offboarding — the `Is Onboarding Workflow` condition routes the call to the correct branch based on which workflow triggered it.

---

## Files

| File | Description |
|---|---|
| `Deploy-PasswordResetLogicApp.ps1` | Deploys the Logic App, enables managed identity, and assigns Graph permissions |
| `LogicApp.json` | Logic App workflow definition template |

---

## Prerequisites

- PowerShell 7+
- `Az.Accounts`, `Az.Resources`, `Az.LogicApp` — installed automatically if missing
- `Microsoft.Graph.Authentication`, `Microsoft.Graph.Applications` — installed automatically if missing
- An existing Resource Group
- A mailbox in Exchange Online for the sender address
- Entra ID P1 or P2 — required for `signInActivity` used in the 5-day check

---

## Quick Start

```powershell
. .\Deploy-PasswordResetLogicApp.ps1

Deploy-PasswordResetLogicApp `
    -SubscriptionId "<subscription-id>" `
    -ResourceGroup "rg-entra-governance-prod" `
    -LogicAppName "la-Password-Reset" `
    -Location "swedencentral" `
    -MailSender "governance@contoso.com" `
    -OnboardingWorkflowIds @("<lifecycle-workflow-id>")
```

**Required permissions to run the script:** `Application.Read.All`, `AppRoleAssignment.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, Contributor on the Resource Group.

---

## Graph permissions assigned to the Logic App

| Permission | Purpose |
|---|---|
| `Mail.Send` | Send email to manager |
| `User.ReadWrite.All` | Reset password via `passwordProfile` |
| `UserAuthenticationMethod.ReadWrite.All` | Reset authentication methods |
| `AuditLog.Read.All` | Read `signInActivity` — requires Entra ID P1/P2 |
| `User.RevokeSessions.All` | Revoke active sessions on offboarding |

---

## After deployment

Register the Logic App as a custom task extension in Lifecycle Workflows and set it to **Sequential** mode so the workflow waits for the Logic App to complete before moving on.

The workflow ID you pass in via `-OnboardingWorkflowIds` determines which branch executes. Add more IDs if multiple onboarding workflows should trigger the same Logic App — the template supports up to two by default (`ONBOARDING_WORKFLOW_ID_1`, `ONBOARDING_WORKFLOW_ID_2`). Add more `equals` blocks in `LogicApp.json` for additional IDs.

---

## Author

**Sandra Saluti** — Identity & Governance Consultant at Epical  
[LinkedIn](https://www.linkedin.com/in/sandra-saluti-6866a686/) · [Blog](https://agderinthe.cloud/author/sandra/)