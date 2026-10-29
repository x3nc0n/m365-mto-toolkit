# Microsoft Sentinel resource-group delegation

This optional component prepares Azure Lighthouse access to an **existing** Microsoft
Sentinel resource group. It is separate from the toolkit's B2B user provisioning,
static target-group membership synchronization, and Defender multitenant management.
Nothing in this repository automatically deploys the delegation.

## Choose the identity model first

* **Lighthouse:** `principalId` is the object ID of a security group in the
  **managing/home tenant**. Its home-tenant members use projected Azure access
  without customer guest accounts. Do not put the synchronized customer group ID
  here. Verify the group and its membership in the home tenant before deployment;
  this script does not query Graph or attest that an object is a group.
* **Direct Azure RBAC with B2B:** invite/synchronize users to the customer tenant,
  add them to the static customer target group, and manually assign that
  **customer group** an appropriate Sentinel Azure role on the intended
  customer resource group/workspace. Verify tenant, group object ID, role, and
  scope in the Azure portal before saving. Direct RBAC role creation/removal is
  deliberately manual, not implemented by this script.

These are distinct access paths. B2B group membership alone does not grant Azure
access, and Lighthouse does not configure Defender XDR roles, Defender multitenant
management, data connectors, or GDAP.

## Prerequisites (manual)

1. Existing customer subscription, resource group, and Sentinel-enabled Log Analytics
   workspace. `workspaceName` is displayed for operator verification only: delegation
   covers the **whole resource group**, not just that workspace. Use a dedicated
   resource group where possible. No resource group, workspace, ingestion, analytics
   rule, connector, or other paid resource is created by this component. Existing
   Sentinel/Log Analytics usage and any subsequent authorized activity can incur costs.
2. Register `Microsoft.OperationalInsights` and `Microsoft.SecurityInsights` in each
   customer subscription and in at least one subscription in the managing tenant.
   Verify `Microsoft.ManagedServices` registration in the customer subscription
   before onboarding. The script does not register providers.
3. Use a customer-tenant account authorized to onboard Lighthouse. Microsoft documents
   subscription Owner or equivalent permissions including
   `Microsoft.Authorization/roleAssignments/read`, `/write`, and `/delete`.
   The account must also be able to create subscription deployments, the nested
   resource-group deployment, and ManagedServices registration resources. Removal
   requires the corresponding registration assignment/definition delete permissions.
   No Managed Services Registration Assignment Delete Role is granted to the home group.
4. PowerShell 7.2+ and existing `Az.Accounts`/`Az.Resources` modules for Apply/Remove.
   Plan and WhatIf need no Az connection. Installing dependencies, signing in, and
   choosing a subscription are explicit operator actions, not script side effects.

## Configuration and least privilege

The following is the Lighthouse portion of the shared configuration; retain the
other required shared-config fields in your real file:

```json
{
  "managingTenant": {
    "tenantId": "11111111-1111-1111-1111-111111111111"
  },
  "managedTenants": [
    {
      "tenantId": "22222222-2222-2222-2222-222222222222",
      "azure": {
        "subscriptionId": "33333333-3333-3333-3333-333333333333",
        "resourceGroup": "existing-sentinel",
        "workspaceName": "existing-workspace"
      },
      "lighthouse": {
        "authorizations": [
          {
            "principalId": "44444444-4444-4444-4444-444444444444",
            "principalIdDisplayName": "Home SOC readers",
            "roleDefinitionId": "8d289c81-5878-46d4-8554-54e1e3d8b5cb"
          }
        ]
      }
    }
  ]
}
```

Only these built-in role IDs are accepted. The shared configuration requires an
explicit `roleDefinitionId`; the example's default choice is **Microsoft Sentinel Reader**:

| Role | ID | Selection |
| --- | --- | --- |
| Microsoft Sentinel Reader | `8d289c81-5878-46d4-8554-54e1e3d8b5cb` | Default, read-only investigation |
| Microsoft Sentinel Responder | `3e150937-b8fe-4cfb-8069-0eaf05ecd056` | Explicit opt-in for incident response |
| Microsoft Sentinel Contributor | `ab8e14d6-4a74-4a29-9ba8-549422addade` | Explicit opt-in for Sentinel configuration |

These are **Sentinel** roles, not generic Reader/Contributor. Owner, generic
Contributor, User Access Administrator, custom roles, eligible authorizations, and
delegated role assignments are not supported. The script neither adds broader
roles nor promises that these roles authorize every possible investigation,
playbook, connector, or data operation.

## Offline review

Run from the repository root with your private config path:

```powershell
.\scripts\Invoke-MtoLighthouse.ps1 -Mode Plan -ConfigPath .\config.local.json `
  -ManagedTenantId 22222222-2222-2222-2222-222222222222
.\scripts\Invoke-MtoLighthouse.ps1 -Mode Apply -ConfigPath .\config.local.json `
  -ManagedTenantId 22222222-2222-2222-2222-222222222222 -WhatIf
```

Both operations validate configuration and inspect any local ownership state but
make **no Azure requests and no state writes**. WhatIf names the exact customer,
scope, assignment, and definition. Neither operation attests that the remote
resource group/workspace/group exists, providers are registered, permissions are
sufficient, or an unrelated delegation does not already exist. Review those manually.

## Operator-controlled apply

These commands are examples for a later authorized deployment; do not run them just
to generate the toolkit:

```powershell
Connect-AzAccount -Tenant 22222222-2222-2222-2222-222222222222
Set-AzContext -Tenant 22222222-2222-2222-2222-222222222222 `
  -Subscription 33333333-3333-3333-3333-333333333333
.\scripts\Invoke-MtoLighthouse.ps1 -Mode Apply -ConfigPath .\config.local.json `
  -ManagedTenantId 22222222-2222-2222-2222-222222222222
```

Apply checks the selected Az tenant **and** subscription, pins that context to each
Azure command, checks collisions, saves ownership state, and submits an incremental
subscription ARM deployment. Despite the template filename `lighthouse-rg.json`,
the **definition is subscription-scoped**; a nested resource-group deployment creates
the assignment referencing that definition. This follows the Lighthouse architecture,
not a workspace-level delegation. `-DeploymentLocation eastus` (default) controls
deployment metadata location, not workspace placement.

Repeated Apply verifies the existing identity, ownership marker, authorizations,
and provisioning status without redeploying a successful delegation. Changes to
principal IDs or roles require removal with the original config, then a reviewed
Apply of the new config. Use one operator/checkout at a time; the local lock cannot
coordinate other machines or unrelated administrators racing ARM deployments.
The standalone ARM template is low-level: deploying it manually bypasses the
script's ownership, role allowlist, and context safeguards.

## State and safe removal

State is kept in gitignored `.local\lighthouse\<assignment-guid>.json`, accompanied
by a local lock file. IDs are deterministic per customer, managing tenant, and
resource group; the state contains an additional random marker written into the
definition description. Preserve the private state securely with the original config.
It contains identifiers, not credentials, but is a trusted ownership record:
do not edit it, accept untrusted copies, or reuse its definition for other assignments.

The script refuses to adopt/overwrite an existing resource without its state, even
when the resource ID is deterministic. If state is missing, removal fails closed:
review ownership in Azure manually rather than reconstructing state to force a delete.
Interrupted or failed deployments retain state for a reviewed retry or cleanup.
Authorization failures and unexpected HTTP responses are not treated as "not found."

```powershell
.\scripts\Invoke-MtoLighthouse.ps1 -Mode Remove -ConfigPath .\config.local.json `
  -ManagedTenantId 22222222-2222-2222-2222-222222222222 -WhatIf
.\scripts\Invoke-MtoLighthouse.ps1 -Mode Remove -ConfigPath .\config.local.json `
  -ManagedTenantId 22222222-2222-2222-2222-222222222222
```

Remove validates local identities/scope and both remote resources before any delete.
It deletes **only the exact tracked assignment**, confirms its absence, rechecks
the definition's ownership, then deletes **only the exact tracked definition**.
State is removed only after confirmed deletion; failures retain recovery state.
The script does not delete resource groups, workspaces, unrelated delegations, or
deployment history. Deleting an ARM deployment record does **not** delete its resources
and is not a rollback mechanism.

After an authorized deployment, sign into the home tenant as a home-group member,
select the delegated directory/subscription, and verify only the intended Sentinel
workspace/resource group appears with the intended privileges. Allow for Azure
propagation. Do not assume Lighthouse alone enables connector setup; Microsoft
documents additional GDAP requirements for that scenario.

## Offline tests

```powershell
Invoke-Pester -Path .\tests\Lighthouse.Tests.ps1 -Output Detailed
```

Tests use a fixture under `.local`, a stub shared-config reader, and mocked Az
commands; no cloud calls or real deployments occur. The fixture is cleaned afterward.

## Official sources

* [Azure Lighthouse architecture](https://learn.microsoft.com/azure/lighthouse/concepts/architecture)
  — subscription registration definitions, scope assignments, onboarding permissions.
* [Onboard a customer](https://learn.microsoft.com/azure/lighthouse/how-to/onboard-customer)
  — customer-side onboarding and authorization requirements.
* [Registration definitions ARM reference](https://learn.microsoft.com/azure/templates/microsoft.managedservices/registrationdefinitions)
  and [registration assignments ARM reference](https://learn.microsoft.com/azure/templates/microsoft.managedservices/registrationassignments)
  — `2022-10-01` properties.
* [Azure built-in security roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security)
  — Microsoft Sentinel Reader, Responder, and Contributor role IDs.
* [Manage multiple tenants in Sentinel](https://learn.microsoft.com/azure/sentinel/multiple-tenants-service-providers)
  — provider registration in both tenants' subscriptions and connector limitations.
