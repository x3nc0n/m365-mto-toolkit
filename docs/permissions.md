# Permissions, licenses and bilateral consent

Use interactive delegated Graph authentication (`Connect-MgGraph -TenantId ...
-ContextScope Process -Scopes ...`). Grant scopes only for the current phase,
disconnect between tenants and remove temporary setup privileges after deployment.
The toolkit never requests Global Administrator or stores client secrets.

## Setup versus runtime

Graph consent and signed-in administrator roles are separate requirements. A
scope is not an administrator role and neither is granted by a source group.
Tenant policy may restrict who can grant administrative consent; use a
Privileged Role Administrator for consent where required by Microsoft guidance.

| Operation / tenant | Delegated Graph scopes used | Administrative authority |
|---|---|---|
| Readiness / either | `Organization.Read.All`, `Policy.Read.All`, `LicenseAssignment.Read.All`; target group check: `Group.Read.All` | Directory/Global Reader or another role permitted for these reads; consent as required |
| Select source group / source | `Group.Read.All`, `User.Read.All` | Read access; no group modification |
| Create empty group / source | `Group.ReadWrite.All`, `User.Read.All` | Groups Administrator, or another principal permitted to create security groups |
| Configure provisioning / source | `Application.ReadWrite.All`, `Synchronization.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `Group.Read.All`, `User.Read.All`, `Policy.Read.All` | Hybrid Identity Administrator for provisioning; Cloud Application Administrator / Application Administrator for application and assignment management; combine only as needed |
| Start / source | `Synchronization.ReadWrite.All`, `Application.Read.All`, `Group.Read.All`, `User.Read.All` | Hybrid Identity Administrator; start also writes the dedicated application's `SyncAll=false` setting |
| Pause / source | `Synchronization.ReadWrite.All`, `Application.Read.All` | Hybrid Identity Administrator |
| Remove source app / source | `Application.ReadWrite.All`, `Synchronization.ReadWrite.All`; `Group.ReadWrite.All` only if deleting an empty toolkit-created group | Application / Cloud Application Administrator; Groups Administrator for group deletion |
| Target group validation | `Group.Read.All` | Read access; no Entra role assignment |
| Manual partner consent / both | Portal; equivalent supported Graph operations require `Policy.Read.All`, `Policy.ReadWrite.CrossTenantAccess` | Security Administrator for cross-tenant access settings |

`Application.ReadWrite.All` includes the application read permission required
alongside `AppRoleAssignment.ReadWrite.All`. Microsoft documents additional
role/consent prerequisites for [Graph cross-tenant configuration](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-configure-graph).
Do not grant all rows to runtime analysts or use an app-only setup identity.

| Azure / Defender operation | Setup authorization | Runtime authorization |
|---|---|---|
| Workspace native RBAC | `Microsoft.Authorization/roleAssignments/read,write,delete` at the workspace; e.g. scoped Role Based Access Control Administrator or User Access Administrator; workspace read | Selected Sentinel Reader, Responder or Contributor on target group |
| Lighthouse registration | Managed subscription deployment/registration-definition rights and assignment rights at the delegated resource group; see Lighthouse guide | Selected Lighthouse authorization for **home** group |
| Defender custom group roles | Target Security Administrator or Defender Unified RBAC Authorization permissions | Minimum target-group role, activated data sources and device/workspace scopes |
| Connect existing Sentinel workspace to Defender | Per current onboarding guidance: Security Administrator plus **unconditional subscription Owner**, or the documented User Access Administrator and Sentinel Contributor combination at the required scopes | Not Owner; validate actual workload/runtime permissions separately |

For workspace onboarding, follow the
[current prerequisite scope details](https://learn.microsoft.com/azure/sentinel/microsoft-sentinel-onboard)
rather than assuming a resource-group Owner or conditional role is sufficient.
Remove setup privileges after setup. Optional PIM requires suitable licenses,
eligible role setup, activation and policy; the toolkit does not create PIM
assignments. Role-assignable group PIM does not turn a synced non-role-assignable
group into a directory-role group.

## Target administrator: consent without broad policy changes

Before any source provisioning, open <https://entra.microsoft.com> in the
**target** tenant:

1. Go to **Entra ID > External Identities > Cross-tenant access settings >
   Organizational settings** and add/select the **source tenant ID**.
2. Export or otherwise securely record the partner configuration and inherited
   defaults before changing anything. Record who approved each change and why.
3. Under inbound access, enable **Cross-tenant sync > Allow user synchronization
   into this tenant** and **Allow group synchronization into this tenant**.
4. Under the partner's inbound **Trust settings**, enable automatic redemption
   (automatically redeem invitations for this tenant). This is not MFA/device
   trust and does not collect legal user consent.
5. Review effective inbound **B2B collaboration** user/group and application
   restrictions. Preserve existing restrictions; allow only necessary source
   analysts/applications following your security review. Do not choose all users
   and all apps merely to get a green test.

Source administrator: open the same organizational partner settings for the
**target tenant ID**, review outbound B2B restrictions, and enable the
partner-specific **outbound automatic redemption** setting. Both directions of
redemption are required for silent B2B provisioning; administration stays one-way.
This does not require reciprocal user synchronization.

The scripts assess default/partner settings and refuse missing source outbound
redemption; they do **not** write either partner/default policy. The target's
user/group sync and consent review is an explicit operator attestation in local
configuration. Group consent has a documented portal control but no corresponding
documented property in the Graph v1.0
[`crossTenantIdentitySyncPolicyPartner`](https://learn.microsoft.com/graph/api/resources/crosstenantidentitysyncpolicypartner).

### Optional MFA trust

Defender MTO recommends trusting MFA claims for each target relationship. It is
**not** enabled automatically. Evaluate the source MFA assurance, target
Conditional Access, authentication strengths, identity risk policies and
customer agreements first. Device/compliant/hybrid-joined trust is a separate
decision; leave it unchanged unless explicitly approved.

If approved, edit **only the target's partner-specific inbound MFA trust**.
Test a pilot sign-in and inspect target sign-in logs. A policy snapshot is not a
reason to overwrite a whole current policy later: for rollback restore only
the previously changed leaf settings, provided no other administrator changed
them since. If concurrent changes exist, reconcile them manually. Never delete
a preexisting partner or replace the tenant-wide defaults.

## Licensing and product capabilities

- Group-and-membership sync: Governance or Entra Suite for **every synced source
  user**. Inventory from `/subscribedSkus` does not prove assignment. Review
  license details and the [current license requirements](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-overview#license-requirements).
- Only internal source users are supported. Group nesting does not extend scope;
  this toolkit rejects nested/non-user members instead of pretending they sync.
- Do not infer Defender entitlement from E5 alone or reject non-E5 tenants.
  Review [Defender prerequisites](https://learn.microsoft.com/defender-xdr/prerequisites)
  for qualifying suites/standalone products, including Business offerings where
  applicable. Sentinel-only use has different requirements.
- Existing Sentinel workspaces, ingestion/retention, queries, automation and other
  Azure resources can incur charges. This toolkit creates no workspace or connector.

## Defender group authorization

At <https://security.microsoft.com/mtp_roles> in the target tenant, create or
select a least-privilege **Unified RBAC** role, assign the synced target group,
select the required data sources and scope, and verify workload activation.
Activation is an intentional authorization-model change: review/import existing
roles before activation so existing operators do not lose access.

Start with **Security operations > Security data > Security data basics (read)**,
and only the needed raw-data read permissions and data sources. For responders,
explicitly assess **Alerts (manage)** and **Response (manage)**, plus any
workload-specific permission, device group or email action needed. Do not
silently grant Authorization/manage permissions or every response action.
Use [the current permissions catalog](https://learn.microsoft.com/defender-xdr/custom-permissions-details)
and [custom-role steps](https://learn.microsoft.com/defender-xdr/create-custom-rbac-roles)
to choose exact supported labels for your workloads. The script's
Reader/Responder/Contributor profile selects **Azure Sentinel RBAC only**;
Defender roles are not auto-created.

Synced target groups are static security groups and not role-assignable. Do not
attempt to assign Entra Security Reader, Security Operator, Security Administrator
or any directory role to this group. If a workload needs individual guest
directory roles or another model, use a separately reviewed, minimal assignment
and document it for offboarding; that is outside this group's automated grants.

B2B has [MSSP/Exchange-backed limitations](https://learn.microsoft.com/defender-xdr/playbook-managed-security).
Some mail/quarantine/Exchange actions may not work for guests even when general
incident access works. Unified RBAC workload support is evolving and Exchange
PowerShell retains its own authorization requirements. Test the exact response
action; never claim an Entra Security Operator or Sentinel Responder role grants
every product operation.

## References

Reviewed against Microsoft Learn on 2026-10-29:

- [Defender MTO requirements and Add tenants](https://learn.microsoft.com/defender-xdr/mto-requirements)
- [Cross-tenant synchronization overview, group constraints and licensing](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-overview)
- [Portal group/user synchronization configuration](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-configure)
- [Supported Graph configuration APIs](https://learn.microsoft.com/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-configure-graph)
- [Graph schema attribute source](https://learn.microsoft.com/graph/api/resources/synchronization-attributemappingsource)
- [Graph ObjectAddOnly mapping behavior](https://learn.microsoft.com/graph/api/resources/synchronization-attributemapping)
- [Defender Unified RBAC support](https://learn.microsoft.com/defender-xdr/manage-rbac)
- [Connect Sentinel to Defender](https://learn.microsoft.com/azure/sentinel/microsoft-sentinel-onboard)
