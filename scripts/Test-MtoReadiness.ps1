#requires -Version 7.2
<#
.SYNOPSIS
Read-only, tenant-specific API assessment; manual portal state stays unverified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][guid]$ManagedTenantId,
    [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Side
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\MtoToolkit.psm1')
$config = Read-MtoConfiguration -Path $ConfigPath
$targets = @($config.managedTenants | Where-Object { $_.tenantId -eq $ManagedTenantId.ToString() })
if ($targets.Count -ne 1) { throw 'Unknown ManagedTenantId.' }
$target = $targets[0]
$sourceId = $config.managingTenant.tenantId
$tenantId = if ($Side -eq 'Source') { $sourceId } else { $target.tenantId }
$partnerId = if ($Side -eq 'Source') { $target.tenantId } else { $sourceId }
Assert-MtoGraphContext -TenantId $tenantId
$organization = @(Get-MtoGraphCollection -Path 'organization?$select=id,verifiedDomains')
if ($organization.Count -ne 1 -or $organization[0].id -ne $tenantId) { throw 'Organization API tenant does not match configuration.' }
$configuredDomain = if ($Side -eq 'Source') { $config.managingTenant.domain } else { $target.domain }
$domainVerified = $configuredDomain -in @($organization[0].verifiedDomains | ForEach-Object { $_.name })
$defaultPolicy = Invoke-MtoGraph -Method GET -Path 'policies/crossTenantAccessPolicy/default'
$partner = Get-MtoOptionalGraph -Path "policies/crossTenantAccessPolicy/partners/$partnerId"
$syncPolicy = if ($Side -eq 'Target' -and $partner) {
    Get-MtoOptionalGraph -Path "policies/crossTenantAccessPolicy/partners/$partnerId/identitySynchronization"
} else { $null }
$skus = @(Get-MtoGraphCollection -Path 'subscribedSkus?$select=skuPartNumber,capabilityStatus')
$automatic = if ($partner) { $partner.automaticUserConsentSettings } else { $null }
$automaticAllowed = if ($automatic) {
    if ($Side -eq 'Source') { $automatic.outboundAllowed } else { $automatic.inboundAllowed }
} else { $null }
$userSync = if ($syncPolicy) { $syncPolicy.userSyncInbound.isSyncAllowed } elseif ($Side -eq 'Target') { $false } else { $null }
[pscustomobject]@{
    Evidence = 'ApiVerified'; Side = $Side; TenantId = $tenantId
    ConfiguredDomainVerified = $domainVerified; PartnerExists = [bool]$partner
    PartnerAutomaticRedemption = $automaticAllowed
    TargetUserSynchronizationAllowed = $userSync
    DefaultPolicyInspected = [bool]$defaultPolicy
    LicenseSkuInventory = @($skus | ForEach-Object { "$($_.skuPartNumber):$($_.capabilityStatus)" })
    LicenseConclusion = 'Unverified: inventory does not prove per-user Governance/Suite assignment or Defender/Sentinel eligibility.'
    PolicyConclusion = 'Review effective B2B app/user restrictions and Conditional Access manually; defaults are never changed by this toolkit.'
}
if ($Side -eq 'Target' -and $target.authorization.targetGroupObjectId) {
    $group = Invoke-MtoGraph -Method GET -Path "groups/$($target.authorization.targetGroupObjectId)?`$select=id,securityEnabled,mailEnabled,groupTypes,isAssignableToRole"
    [pscustomobject]@{
        Evidence = 'ApiVerified'; TargetGroupId = $group.id
        StaticSecurityGroup = ($group.securityEnabled -and -not $group.mailEnabled -and 'DynamicMembership' -notin $group.groupTypes)
        RoleAssignable = $group.isAssignableToRole
        Provenance = 'Operator must match this ID to the source-group provisioning event; a matching name is insufficient.'
    }
}
foreach ($key in $target.attestations.Keys | Sort-Object) {
    [pscustomobject]@{
        Evidence = 'OperatorAttestation'; Check = $key; Attested = $target.attestations[$key]
        Verification = 'Not independently verified by this script'
    }
}
[pscustomobject]@{
    Evidence = 'ManualUnverified'
    Checks = @(
        'Target inbound GROUP synchronization switch (not exposed by the documented v1.0 identity sync policy resource)'
        'Provisioning logs: source group -> correct target static group, users and memberships'
        'Per-user Governance/Suite licensing, privacy/compliance agreement'
        'Defender product licenses, activated Unified RBAC workload coverage and child-group role assignments'
        'Native Sentinel Azure RBAC; managed-tenant workspace connected in Defender'
        'Direct Defender access, Defender MTO Add tenants, cross-tenant workspace() query'
        'Lighthouse provider registration in both customer and at least one managing subscription'
    )
}
