# Microsoft Defender / Sentinel B2B multitenant toolkit

A PowerShell 7 toolkit for **one-way B2B access** from a managing tenant to managed
tenants. The primary model synchronizes a dedicated source security group, its
internal users and direct memberships into each target, then authorizes the
**target group** for supported Defender and Azure experiences.

This is not a GDAP/CSP onboarding tool, an Entra tenant hierarchy, or an Entra
Multitenant Organization membership tool. No tenant is configured merely by
cloning this repository. All examples are fictional.

## What this implements

| Component | Implementation |
|---|---|
| Configuration and planning | JSON schema, distinct tenant IDs, multiple targets, closed approval gates, local-only Plan |
| Source identities | Select an existing security group or create an empty dedicated group |
| Provisioning | Dedicated Microsoft gallery application and `Azure2Azure` job; assigned-group scope; users, group and memberships; new external users mapped to **Guest** |
| Synchronization lifecycle | Explicit Configure / Start / Pause / Remove phases, context assertions, checkpoints and ownership checks |
| Target authorization | Native, existing-workspace Azure RBAC for the child group: Sentinel Reader by default; Responder / Contributor opt-in |
| Cross-tenant Sentinel | Resource-group-scoped Azure Lighthouse delegation with **home-tenant** group authorizations |
| Readiness | Read-only Graph assessment; separates API evidence, operator attestations and unverified portal state |
| Defender permissions and tenant selection | Documented portal steps; no undocumented Defender APIs |

**Group synchronization requires Microsoft Entra ID Governance or Entra Suite for
each synchronized source user.** This is different from group-scoped *user-only*
synchronization, which can use Entra ID P1. This version deliberately implements
the group-and-membership model, not an automatic lower-license fallback.

## Architecture

```text
Managing tenant                         Managed tenant (one per customer)
  Internal analysts                       B2B external users (new users: Guest)
       |                                          |
  Dedicated security group -- sync --> Static security group + direct membership
       |                                          |
       |                                 Defender Unified RBAC (manual)
       |                                 Native workspace Azure RBAC (script)
       |
  Home security group ------ Lighthouse --> Delegated resource group
                                              Sentinel workspace + XDR
                                              Data and billing stay here
```

The home group used for Lighthouse may be the source analyst group, but its
**home object ID** is not the synced group's **target object ID**. Synchronization
is identity lifecycle management, not authorization. Adding a person to the
source group only grants access after target roles are configured and provisioning
has completed. Do not put unrelated users or nested groups in this group.

## Quickstart

Use **PowerShell 7.2 or newer** in the repository root. Start in a test tenant pair
with one internal test analyst. Do not use production administrators as test users.

```powershell
# Install only the modules needed for the phase you will run.
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Az.Accounts, Az.Resources -Scope CurrentUser

New-Item -ItemType Directory .\.local -Force
Copy-Item .\config\example.json .\.local\configuration.local.json
$configPath = '.\.local\configuration.local.json'
# Edit tenant IDs/domains, source group, existing Azure scope and home Lighthouse group.
# Keep approval gates false until their documented checks are complete.
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$sourceId = $config.managingTenant.tenantId
$targetId = $config.managedTenants[0].tenantId

# No authentication, cloud requests or mutations:
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Phase Configure
.\scripts\Invoke-MtoTargetAccess.ps1 -ConfigPath $configPath -ManagedTenantId $targetId
.\scripts\Invoke-MtoLighthouse.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Mode Plan
```

1. **Review prerequisites and consent.** Follow [permissions and bilateral
   consent](docs/permissions.md). The target admin explicitly enables inbound
   **user and group synchronization**; target inbound and source outbound
   automatic redemption must both be configured. Scripts never change default
   policies, B2B app/user restrictions, MFA/device trust or Conditional Access.
2. **Assess each side.** Authenticate separately; never reuse an assumed tenant
   context. Readiness is read-only and does not attest that licensing or portal
   configuration is correct.

```powershell
Connect-MgGraph -TenantId $targetId -ContextScope Process `
  -Scopes 'Organization.Read.All','Policy.Read.All','LicenseAssignment.Read.All','Group.Read.All'
.\scripts\Test-MtoReadiness.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Side Target
Disconnect-MgGraph

Connect-MgGraph -TenantId $sourceId -ContextScope Process `
  -Scopes 'Organization.Read.All','Policy.Read.All','LicenseAssignment.Read.All','Group.Read.All'
.\scripts\Test-MtoReadiness.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Side Source
Disconnect-MgGraph
```

3. **Create/select the source group.** Sign in with the scoped setup permissions
   from the matrix. `-Mode Apply -WhatIf` performs reads but makes no cloud writes.
   `-Confirm:$false` deliberately skips the high-impact prompt, not safety gates.

```powershell
Connect-MgGraph -TenantId $sourceId -ContextScope Process -Scopes 'Group.ReadWrite.All','User.Read.All'
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId `
  -Phase SourceGroup -Mode Apply -WhatIf
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId `
  -Phase SourceGroup -Mode Apply
Disconnect-MgGraph
```

Add **only direct internal analysts** to this dedicated group in
<https://entra.microsoft.com> > Entra ID > Groups. Source group changes are
intentional access changes for every role assigned to its target replica.

4. **Configure, review, then start.** After verifying license assignment, target
   consent and existing-user matching, set only the corresponding local
   attestations and `reviewedMatchingAndLifecycle` to `true`. Configure leaves the
   job paused. Review the provisioning app's mappings, assigned scope, deletion
   threshold and notification settings before explicitly setting `approveStart`.

```powershell
Connect-MgGraph -TenantId $sourceId -ContextScope Process -Scopes `
  'Application.ReadWrite.All','Synchronization.ReadWrite.All',`
  'AppRoleAssignment.ReadWrite.All','Group.Read.All','User.Read.All','Policy.Read.All'
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId `
  -Phase Configure -Mode Apply -WhatIf
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId `
  -Phase Configure -Mode Apply
# Review docs\operations.md and the paused app in Entra before opening approveStart.
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId `
  -Phase Start -Mode Apply
Disconnect-MgGraph
```

The synchronization service, not an invitation-email loop, provisions and reconciles
B2B users and membership on reruns. New users are Guest; `ObjectAddOnly` does not
reclassify matched preexisting users. **Matching and later deprovisioning can still
affect preexisting identities.** Review the pilot provisioning logs before expansion.

5. **Authorize the actual target group.** Find its object ID using the provisioning
   logs' source-to-target mapping, not its name, and put it in
   `authorization.targetGroupObjectId` in the local config.

```powershell
Connect-MgGraph -TenantId $targetId -ContextScope Process -Scopes 'Group.Read.All'
Connect-AzAccount -Tenant $targetId -Subscription $config.managedTenants[0].azure.subscriptionId
.\scripts\Invoke-MtoTargetAccess.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Mode Apply -WhatIf
.\scripts\Invoke-MtoTargetAccess.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Mode Apply
Disconnect-MgGraph
Disconnect-AzAccount
```

This grants only the selected Sentinel role at the **existing workspace**.
It does not create a workspace, connect a data source, assign Defender roles, or
grant subscription Owner. Configure Defender Unified RBAC for the child group
using [the portal milestones](docs/operations.md). A synced group is **not
role-assignable**: do not assign it Entra directory roles.

6. **Delegate the Sentinel resource group through Lighthouse.** Follow
   [Lighthouse setup](docs/lighthouse.md), including provider-registration checks
   in the managed subscription and at least one managing subscription. This uses
   home-group authorizations and does not replace native B2B Azure RBAC.
7. **Finish the manual milestones.** Validate direct access, connect the existing
   Sentinel workspace in its **managed tenant**, and use
   <https://mto.security.microsoft.com/> > **Add tenants**.
   [Detailed verification and offboarding](docs/operations.md) includes expected
   evidence and emergency access revocation.

## Boundaries and caveats

- "Parent"/"child" are operational labels only. No reciprocal administration or
  Entra Multitenant Organization membership is established.
- For supported Partner Center/CSP administration, assess GDAP first. This repo
  implements **B2B**, not GDAP. [Defender MTO requirements](https://learn.microsoft.com/defender-xdr/mto-requirements)
  currently require B2B for Sentinel MTO data and Lighthouse for cross-tenant
  queries. [Unified RBAC documentation](https://learn.microsoft.com/defender-xdr/manage-rbac)
  separately describes GDAP-group support for Sentinel role assignments; support
  differs by surface and is evolving. Do not interpret either as a blanket rule
  that all partners must use GDAP or that GDAP replaces this Sentinel B2B path.
- Cross-organization sync requires explicit customer approval, privacy/data
  minimization review and appropriate agreements. Microsoft's
  [overview](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-overview)
  discusses cross-organization use, while its FAQ recommends considering
  entitlement management for cross-organization lifecycle scenarios. This is
  not a promise of universal MSSP/customer eligibility or a license entitlement.
- Group sync is same-cloud, direct-membership only; nested groups do not
  synchronize transitively. Target groups are static security groups, not
  role-assignable groups. Confirm feature availability in your cloud/tenant.
- No E5-only gate: qualifying Defender offerings include other suites and
  standalone plans. Sentinel-only Defender portal use need not have XDR/E5.
  SKU inventory is **not** per-user license or feature validation.
- Defender product/workload scope matters. A Sentinel Responder grant or an
  Entra Security Operator role does not guarantee every Defender response action.
  Guest/Exchange-backed actions, including some quarantine workflows, have
  additional limitations. See [permissions](docs/permissions.md).
- No default-policy writes, B2B direct connect, device/compliance trust, automatic
  PIM activation, paid resources, data connectors, MTO membership, or automatic
  Defender portal onboarding/tenant selection.
- Portal-dependent tasks and target group-sync consent are deliberately manual.
  The documented Graph v1.0 identity-sync resource exposes `userSyncInbound`,
  not a documented group-consent field. No undocumented API is called.
- Protect and back up `.local` outside the public repo. It contains identifiers
  and ownership state, not access tokens. Losing it requires manual reconciliation;
  resources are never adopted or deleted just because their name matches.

## Offline validation

No Azure credentials, Graph credentials, tenant writes or Azure secrets are
required by tests or CI.

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
Import-Module Pester -RequiredVersion 5.7.1
Invoke-Pester .\tests -Output Detailed
Invoke-ScriptAnalyzer .\src -Recurse -Severity Warning,Error
Invoke-ScriptAnalyzer .\scripts -Recurse -Severity Warning,Error
```

These are **offline mock tests**, not proof that any real tenant is configured.
See [official references and permission matrix](docs/permissions.md).
