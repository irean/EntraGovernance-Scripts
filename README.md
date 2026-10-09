# EntraGovernance-Scripts

Practical PowerShell scripts and deployment frameworks for Entra ID Identity Governance — focusing on directory extensions, guest lifecycle, access packages, helper utilities, and cloud orchestration.

Built from real-world consulting work, these tools solve integration problems that standard documentation often glosses over.

## Repository Structure

| Directory | Description |
| :--- | :--- |
| **`SiSGovernance/`** | PowerShell module for access packages, their resources and assignments in bulk, and distribution lists → access packages. See its [README](SiSGovernance/README.md). |
| **`Access Packages/`** | Production scripts and template frameworks for managing Entra ID Access Packages. |
| **`DirectoryExtensions/`** | Deployment scripts for managing Entra ID directory extensions as core governance metadata. |
| **`Guest Users/`** | Scripts for external guest account lifecycle, provisioning, and access management governance. |
| **`HelperFunctions/`** | Shared PowerShell utility functions, including environment validation and structured logging modules. |
| **`Logic Apps/`** | Enterprise orchestration workloads and automated cloud workflows. Includes: <br>• **`Distribution List Membership Bicep`**: Automated management of Exchange Online distribution lists using a zero-secrets Bicep framework.<br>• **`Manager Flag Sync Logic App`**: Workflow for synchronization and management of internal manager flags and attributes.<br>• **`Password Reset Logic App`**: Automation for self-service or governed password reset handling and tracking. |
| **`docs/`** | Architectural notes, naming guidelines, and internal environment standards (e.g., `entra id naming standard`). |

## Releases and Bundles
Pre-built components and structured zip deployments are available under the **[Releases](https://github.com)** section. You can download pre-packaged assets (such as `Distribution.List.Membership.zip`) directly without needing to clone the entire development repository.

## About the Author
Sandra Saluti is a Solutions Owner at Epical, working with Microsoft's identity solutions. Her technical focus includes Microsoft Entra ID Governance, identity lifecycle automation and PowerShell. She builds tools and automation based on practical experience with enterprise identity environments.

* **Blog:** [agderinthecloud.cloud](https://agderinthe.cloud)
* **LinkedIn:** [linkedin.com](https://www.linkedin.com/in/sandra-saluti-6866a686/)