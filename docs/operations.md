# Pilot, verification, lifecycle and recovery

## Review the paused provisioning application

After Configure, use <https://entra.microsoft.com> in the source tenant:
**Entra ID > External Identities > Cross-tenant synchronization > Configurations**.
Find the dedicated `MTO-<target-id>-<ownership-token>` application recorded in
`.local\sync-<source-id>-<target-id>.json`.

Verify before Start:

1. Target tenant ID is correct; connection validation succeeds.
2. Provisioning **Settings > Scope = Sync only assigned users and groups**.
   Only the dedicated source group is assigned. No direct user/app assignments
   broaden its scope. The script writes `SyncAll=false` again before Start.
3. **Provision Microsoft Entra ID Groups** is enabled, with membership mappings.
   The Microsoft template's other mappings remain unchanged. Review their data
   minimization implications; do not export unnecessary personal attributes.
4. User `userType` mapping is constant **Guest**, **Only during object creation**
   (`ObjectAddOnly`). Matched preexisting users retain their user type.
5. Configure provisioning error notifications and accidental-deletion prevention
   appropriate to the deployment. These portal controls are not automated.
6. Review existing target users that can match by the template's matching
   attributes. Synchronization may manage matched identities' attributes and
   lifecycle; preserving their user type does not exempt them from deprovisioning.
   Pilot with a dedicated test identity and retain target object IDs.

Then explicitly open the local `approveStart` gate and run Start. The initial
cycle can take longer than subsequent cycles, which run approximately every
**40 minutes**. There is no immediate-access or immediate-revocation guarantee.
Use Entra provisioning logs and the dedicated application's provisioning status;
do not treat a successful Start HTTP response as successful identity provisioning.

For the pilot, verify source-to-target object mappings for **the group and each
user**, membership convergence and external Guest type for newly created users.
The group in the target is static and not role-assignable. Put its actual ID in
local configuration only after matching the provisioning event. Name equality
is not identity or provenance verification.

## Manual access milestones

These are separate milestones, not script successes:

| Check | Action / evidence |
|---|---|
| B2B identity ready | With bilateral automatic redemption, provisioning can redeem automatically. If an invitation already exists or redemption remains pending, the user accepts through the approved tenant invitation flow. Do not publish redemption URLs or transcripts. |
| Organization visible | Analyst opens <https://myaccount.microsoft.com/organizations>; target appears under other organizations. |
| Direct Defender access | Analyst opens `https://security.microsoft.com/?tid=<target-tenant-id>` and verifies the intended tenant, data and read-only actions first. |
| Target group roles | Customer admin assigns the verified child group in <https://security.microsoft.com/mtp_roles>, with reviewed workload activation and data/device/workspace scope. |
| Native Azure access | Verify the child's workspace-scoped Sentinel role; test the existing workspace in the target Azure/Defender portal. Lighthouse alone does not grant Defender/M365 access. |
| Workspace connected | In **target** Defender portal, **System > Settings > Microsoft Sentinel > Connect a workspace** (or Sentinel onboarding wizard), select the existing target-tenant workspace and complete the current documented setup. Portal wording can evolve. |
| Multitenant selection | Analyst signs in to <https://mto.security.microsoft.com/> > **Add tenants** > selects target > **Add**. Current documented limit: 100 targets. |
| Cross-tenant hunting | Verify Lighthouse delegation and run an authorized `workspace()` query against target data; record actual query/access results privately. |
| Response pilot | If approved, test one safe workload-specific response action. An incident-read test does not prove quarantine, endpoint response or Exchange actions. |

Keep the XDR connector, workspace, data and billing in the managed tenant.
Do not connect a managed tenant's XDR into a managing-tenant workspace as a
shortcut. Do not invoke internal Defender onboarding or MTO endpoints.

`Test-MtoReadiness.ps1` labels output:

- **ApiVerified**: current tenant, policies, SKU inventory and optional target
  group shape queried from supported APIs. This is not end-to-end readiness.
- **OperatorAttestation**: boolean supplied by the operator; never independently
  certified by this toolkit.
- **ManualUnverified**: portal, licensing, provisioning provenance and runtime
  access milestones that still need direct evidence.

No offline/mock test is live tenant validation. Keep logs and sign-in evidence
in protected local storage, not Git.

## Add the next target

Add a distinct entry to `managedTenants`; keep one dedicated source scope per
target, or deliberately document the blast radius if reusing an existing group.
Use new target-specific local state. Repeat target consent, source configuration,
pilot, target roles, Lighthouse and portal selection. No reciprocal rights are
required. Existing relationships are never inferred from domain display names.

## Offboarding

**Urgent revocation is target-side, not a 40-minute sync wait.** Remove target
Defender role assignments, remove/revoke Azure access, block affected external
users and revoke sessions using approved incident procedures. Source group
removal or pausing a job does not guarantee immediate loss of active access.
Assess Lighthouse home-group access independently.

For planned offboarding:

1. Record every target Defender assignment and native Azure assignment, including
   any manually created individual guest roles. Remove only intended customer
   access. URBAC and Azure grants can overlap; inspect effective permissions.
2. Remove only toolkit-created native Azure workspace access:

```powershell
.\scripts\Invoke-MtoTargetAccess.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Mode Remove -WhatIf
.\scripts\Invoke-MtoTargetAccess.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Mode Remove
```

3. Remove toolkit-owned Lighthouse assignments/definition using its recorded
   state and [Lighthouse guide](lighthouse.md). Do not remove a shared or preexisting
   delegation or delete the resource group/workspace.
4. Decide target identity retention **before** removing source scope. Removing
   users/groups from provisioning scope normally deprovisions/soft-deletes the
   target objects, potentially including matched preexisting accounts. Review
   downstream references, retention and restore requirements with the customer.
   Either allow a reviewed final deprovisioning cycle and inspect logs, or pause
   and explicitly retain/reconcile the target objects. Do not assume deleting
   the source app cleans up target identities.
5. Pause/remove the dedicated source application:

```powershell
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Phase Pause -Mode Apply
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Phase Remove -Mode Apply -WhatIf
.\scripts\Invoke-MtoSync.ps1 -ConfigPath $configPath -ManagedTenantId $targetId -Phase Remove -Mode Apply
# Optional only after clearing/reviewing ALL uses; empty toolkit-created group only:
# ... -Phase Remove -Mode Apply -RemoveEmptySourceGroup
```

The source removal never deletes target guests/groups or partner policies.
An existing source group is never deleted. A created source group is preserved
unless `-RemoveEmptySourceGroup` is explicit and it is empty with matching
ownership marker.

6. Reconcile retained target users/groups manually; never bulk-delete all guests
   from a tenant or all objects with a name prefix. Remove the tenant from the
   analyst's Defender MTO selection. Restore only deliberately changed partner
   leaf settings after checking for concurrent changes; retain preexisting
   partner/default policies.

## Errors and recovery

- **401/403 is not absence.** Scripts stop on authentication, permission or policy
  failures. Reconnect to the exact tenant with the matrix's scopes/admin roles;
  do not compensate with Global Administrator.
- **Context mismatch:** scripts will not switch tenants/subscriptions implicitly.
  Sign in separately, select the correct subscription, then retry.
- **Conditional Access/MFA:** inspect target sign-in logs and correlation IDs,
  authentication strengths, cross-tenant app/user restrictions and guest
  challenges. Only enable partner MFA trust after review; never open all apps.
- **Missing group mapping:** template/feature availability may differ. The script
  refuses to invent mappings. Check the current Microsoft portal/feature support
  and licensing, then reconcile the paused template; do not start a user-only job
  while believing a group will appear.
- **Propagation:** allow service principal, assignment, policy, identity and role
  replication; refresh tokens/sign out and back in. Recheck direct target access
  before diagnosing MTO aggregation. A portal refresh is not proof of revocation.
- **Concurrent runs:** mutation scripts use local exclusive state locks. Run one
  writer per relationship. Do not run separate copies of the repository against
  the same relationship with independent state.
- **Interrupted creation:** the source script writes `pendingOperation` before
  non-idempotent creates. It stops on subsequent attempts rather than duplicating
  groups/apps/jobs. Review the exact tenant, ownership token, display name,
  creation audit event, app/template IDs and assignment principal before an
  administrator reconciles the recorded ID and clears the pending field in the
  protected state. If ownership cannot be proved, do not adopt/delete it.
- **Interrupted Azure assignment:** a PendingCreate record is not proof of
  ownership. Verify the exact assignment ID, scope, role, principal and creation
  audit event before marking it Created. Do not delete unknown assignments.
- **Lost state:** restore a protected backup. No name-based mass adoption/deletion
  is provided. If recovery is impossible, inventory and reconcile resources with
  both administrators before starting a fresh relationship.
- **Partial removal:** restore missing privileges/context and rerun after
  verifying recorded IDs. Typed 404 is treated as absence only for explicit GET
  checks; other failures surface. Never force-delete a parent scope to "finish".

The `.local` directory is sensitive operational metadata. Keep it gitignored,
protected by filesystem access controls and backed up in your organization's
approved storage. No tokens or invitation redemption URLs belong in it.
