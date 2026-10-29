#requires -Version 7.2
<#
.SYNOPSIS
Plans or manages a dedicated, one-way group/user provisioning configuration.
.DESCRIPTION
Plan is local-only. Apply uses the current delegated Graph context in the source
tenant. Target policies are assessed separately and changed manually, not overwritten.
Never deletes target users/groups or preexisting source resources.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][guid]$ManagedTenantId,
    [Parameter(Mandatory)][ValidateSet('SourceGroup','Configure','Start','Pause','Remove')][string]$Phase,
    [ValidateSet('Plan','Apply')][string]$Mode = 'Plan',
    [string]$StateDirectory = (Join-Path $PSScriptRoot '..\.local'),
    [switch]$RemoveEmptySourceGroup
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\MtoToolkit.psm1')
$config = Read-MtoConfiguration -Path $ConfigPath
$target = @($config.managedTenants | Where-Object { $_.tenantId -eq $ManagedTenantId.ToString() })
if ($target.Count -ne 1) { throw 'ManagedTenantId must select exactly one configured target.' }
$target = $target[0]
$sourceId = $config.managingTenant.tenantId
$targetId = $target.tenantId
$statePath = Join-Path $StateDirectory "sync-$sourceId-$targetId.json"
$state = Read-MtoState -Path $statePath -SourceTenantId $sourceId -TargetTenantId $targetId
$applicationName = "MTO-$targetId-$($state.ownershipToken)"

if ($Mode -eq 'Plan') {
    [pscustomobject]@{
        Evidence = 'LocalPlan'; Phase = $Phase; SourceTenantId = $sourceId
        TargetTenantId = $targetId; GroupMode = 'GroupsAndDirectInternalMembers'
        CreatesTargetUsersAs = 'Guest (ObjectAddOnly)'
        SourceGroup = $target.sourceGroup; StateExists = (Test-Path -LiteralPath $statePath)
        Note = 'No API checks or writes. Run Test-MtoReadiness in each tenant; review docs before Apply.'
    }
    return
}
Assert-MtoGraphContext -TenantId $sourceId
$stateLock = if (-not $WhatIfPreference) { Enter-MtoStateLock -Path $statePath } else { $null }
try {
$state = Read-MtoState -Path $statePath -SourceTenantId $sourceId -TargetTenantId $targetId
$applicationName = "MTO-$targetId-$($state.ownershipToken)"
if ($state.pendingOperation) {
    throw "Unresolved operation '$($state.pendingOperation)'. Follow docs\operations.md recovery; refusing duplicate creation."
}
if ($state.groupId -and -not $target.sourceGroup.create -and $state.groupId -ne $target.sourceGroup.objectId) {
    throw 'Configured source group differs from saved relationship. Use a new relationship after explicit offboarding.'
}

function Save-Checkpoint {
    Save-MtoState -State $state -Path $statePath
}

function Assert-OwnedApplication {
    if (-not $state.servicePrincipalId -or -not $state.applicationId) { throw 'Configure this relationship first.' }
    $sp = Get-MtoOptionalGraph -Path "servicePrincipals/$($state.servicePrincipalId)"
    if ($sp -and ($sp.displayName -ne $applicationName -or $sp.applicationTemplateId -ne '518e5f48-1fc8-4c48-9387-9fdf28b0dfe7')) {
        throw 'Application ownership check failed.'
    }
    $application = Get-MtoOptionalGraph -Path "applications/$($state.applicationId)"
    if ($application -and ($application.displayName -ne $applicationName -or ($sp -and $application.appId -ne $sp.appId))) {
        throw 'Application registration ownership check failed.'
    }
    return $sp
}

function Get-SourceGroup {
    $id = if ($state.groupId) { $state.groupId } else { $target.sourceGroup.objectId }
    if (-not $id) { throw 'Run SourceGroup first.' }
    $group = Invoke-MtoGraph -Method GET -Path "groups/$id"
    if (-not $group.securityEnabled -or $group.mailEnabled -or 'Unified' -in $group.groupTypes) {
        throw 'Source must be a security group, not a Microsoft 365 or mail-enabled group.'
    }
    if ($state.groupCreated -and $group.description -ne "MtoToolkit:$($state.ownershipToken)") {
        throw 'Source group ownership marker changed.'
    }
    return $group
}

function Test-DirectMember {
    param([Parameter(Mandatory)][string]$GroupId)
    $members = @(Get-MtoGraphCollection -Path "groups/$GroupId/members?`$select=id")
    foreach ($member in $members) {
        if ($member['@odata.type'] -ne '#microsoft.graph.user') {
            throw 'Only direct internal users are supported. Remove nested groups/non-user objects from this dedicated group.'
        }
        $user = Invoke-MtoGraph -Method GET -Path "users/$($member.id)?`$select=id,userType,creationType,externalUserState"
        if ($user.userType -ne 'Member' -or $user.creationType -eq 'Invitation' -or $user.externalUserState) {
            throw 'Source scope contains an external user. Only internal source members are supported.'
        }
    }
    return $members.Count
}

switch ($Phase) {
    'SourceGroup' {
        if ($state.groupId) {
            $group = Get-SourceGroup
            [pscustomobject]@{ Evidence = 'ApiVerified'; GroupId = $group.id; Created = $state.groupCreated }
            return
        }
        if (-not $target.sourceGroup.create) {
            $group = Get-SourceGroup
            $null = Test-DirectMember -GroupId $group.id
            if ($PSCmdlet.ShouldProcess($group.id, 'Record existing source security group locally (no cloud mutation)')) {
                $state.groupId = $group.id
                Save-Checkpoint
            }
            return
        }
        $name = $target.sourceGroup.displayName
        $collisions = @(Get-MtoGraphCollection -Path "groups?`$filter=displayName eq '$name'&`$select=id")
        if ($collisions.Count) { throw 'A source group with this name exists. Select its objectId explicitly; it will not be adopted or overwritten.' }
        if ($PSCmdlet.ShouldProcess("$sourceId / $name", 'Create empty dedicated analyst security group')) {
            $state.pendingOperation = 'CreateSourceGroup'
            Save-Checkpoint
            $group = Invoke-MtoGraph -Method POST -Path 'groups' -Body @{
                displayName = $name; description = "MtoToolkit:$($state.ownershipToken)"
                mailEnabled = $false; mailNickname = "mto$($state.ownershipToken.Replace('-',''))"
                securityEnabled = $true; groupTypes = @()
            }
            $state.groupId = $group.id
            $state.groupCreated = $true
            $state.pendingOperation = $null
            Save-Checkpoint
            [pscustomobject]@{ Evidence = 'ApiVerified'; GroupId = $group.id; Created = $true }
        }
    }
    'Configure' {
        if (-not $target.attestations.governanceOrSuiteForEverySyncedUser -or
            -not $target.attestations.targetGroupSyncEnabled -or -not $target.attestations.targetConsentApproved -or
            -not $target.synchronization.reviewedMatchingAndLifecycle) {
            throw 'Review source Governance/Suite licensing, target user+group consent and matching/lifecycle; explicitly set the corresponding attestations.'
        }
        $group = Get-SourceGroup
        $null = Test-DirectMember -GroupId $group.id
        $partner = Invoke-MtoGraph -Method GET -Path "policies/crossTenantAccessPolicy/partners/$targetId"
        if (-not $partner.automaticUserConsentSettings.outboundAllowed) {
            throw 'Source partner-specific outbound automatic redemption must be enabled by its admin. See docs\permissions.md.'
        }
        if ($state.servicePrincipalId) {
            $sp = Assert-OwnedApplication
            if (-not $sp) { throw 'Owned service principal missing; recover or offboard state explicitly.' }
            if ($state.configured) {
                [pscustomobject]@{ Evidence = 'ApiVerified'; ServicePrincipalId = $sp.id; JobId = $state.jobId; Note = 'Already configured; use Start separately.' }
                return
            }
        }
        if ($PSCmdlet.ShouldProcess("$sourceId -> $targetId", 'Create/configure dedicated GROUP+USER sync, assigned-group scope, Guest mapping; leave paused')) {
            if (-not $state.servicePrincipalId) {
                $collision = @(Get-MtoGraphCollection -Path "servicePrincipals?`$filter=displayName eq '$applicationName'&`$select=id")
                if ($collision.Count) { throw 'Untracked application collision. Reconcile local state; refusing to adopt.' }
                $state.pendingOperation = 'InstantiateApplication'
                Save-Checkpoint
                $instance = Invoke-MtoGraph -Method POST -Path 'applicationTemplates/518e5f48-1fc8-4c48-9387-9fdf28b0dfe7/instantiate' -Body @{ displayName = $applicationName }
                $state.servicePrincipalId = $instance.servicePrincipal.id
                $state.applicationId = $instance.application.id
                $state.pendingOperation = $null
                Save-Checkpoint
            }
            $sp = Assert-OwnedApplication
            if (-not $sp) { throw 'Service principal not available yet. Wait for propagation and retry.' }
            $spPath = "servicePrincipals/$($sp.id)"
            if (-not $state.jobId) {
                $jobs = @(Get-MtoGraphCollection -Path "$spPath/synchronization/jobs")
                if ($jobs.Count) { throw 'Untracked provisioning job exists; reconcile state instead of duplicating.' }
                $state.pendingOperation = 'CreateJob'
                Save-Checkpoint
                $job = Invoke-MtoGraph -Method POST -Path "$spPath/synchronization/jobs" -Body @{ templateId = 'Azure2Azure' }
                $state.jobId = $job.id
                $state.pendingOperation = $null
                Save-Checkpoint
            }
            $jobPath = "$spPath/synchronization/jobs/$($state.jobId)"
            $job = Invoke-MtoGraph -Method GET -Path $jobPath
            if ($job.templateId -ne 'Azure2Azure' -or $job.schedule.state -ne 'Disabled') {
                throw 'Expected paused Azure2Azure job. Pause before configuring.'
            }
            $null = Invoke-MtoGraph -Method POST -Path "$spPath/synchronization/jobs/validateCredentials" -Body @{
                useSavedCredentials = $false; templateId = 'Azure2Azure'
                credentials = @(@{ key = 'CompanyId'; value = $targetId }, @{ key = 'AuthenticationType'; value = 'SyncPolicy' })
            }
            $null = Invoke-MtoGraph -Method PUT -Path "$spPath/synchronization/secrets" -Body @{
                value = @(
                    @{ key = 'AuthenticationType'; value = 'SyncPolicy' }
                    @{ key = 'CompanyId'; value = $targetId }
                    @{ key = 'SyncAll'; value = 'false' }
                )
            }
            $schema = Invoke-MtoGraph -Method GET -Path "$jobPath/schema"
            $schema = ConvertTo-MtoGroupSyncSchema -Schema $schema
            $null = Invoke-MtoGraph -Method PUT -Path "$jobPath/schema" -Body $schema
            $assignments = @(Get-MtoGraphCollection -Path "$spPath/appRoleAssignedTo")
            if (@($assignments | Where-Object { $_.principalId -ne $group.id }).Count) {
                throw 'Unexpected app assignments broaden the scope; remove them explicitly before continuing.'
            }
            $assignment = @($assignments | Where-Object { $_.principalId -eq $group.id })
            if (-not $assignment.Count) {
                $roles = @($sp.appRoles | Where-Object { $_.isEnabled -and 'User' -in $_.allowedMemberTypes })
                if ($roles.Count -ne 1) { throw 'Expected exactly one enabled provisioning app role.' }
                $state.pendingOperation = 'AssignSourceGroup'
                Save-Checkpoint
                $created = Invoke-MtoGraph -Method POST -Path "$spPath/appRoleAssignedTo" -Body @{
                    principalId = $group.id; resourceId = $sp.id; appRoleId = $roles[0].id
                }
                $state.assignmentId = $created.id
                $state.pendingOperation = $null
                Save-Checkpoint
            }
            $state.configured = $true
            Save-Checkpoint
            [pscustomobject]@{ Evidence = 'ApiVerified'; ServicePrincipalId = $sp.id; JobId = $state.jobId; Status = 'ConfiguredPaused' }
        }
    }
    'Start' {
        if (-not $state.configured -or -not $target.synchronization.approveStart -or
            -not $target.synchronization.reviewedMatchingAndLifecycle -or
            -not $target.attestations.governanceOrSuiteForEverySyncedUser -or
            -not $target.attestations.targetGroupSyncEnabled -or -not $target.attestations.targetConsentApproved) {
            throw 'Start requires configured state, explicit approveStart, matching review, license and target consent attestations.'
        }
        $sp = Assert-OwnedApplication
        if (-not $sp) { throw 'Owned service principal missing.' }
        $group = Get-SourceGroup
        if ((Test-DirectMember -GroupId $group.id) -lt 1) { throw 'Add at least one internal analyst directly to the source group first.' }
        $assignments = @(Get-MtoGraphCollection -Path "servicePrincipals/$($sp.id)/appRoleAssignedTo")
        if ($assignments.Count -ne 1 -or $assignments[0].principalId -ne $group.id) { throw 'Scope drift: only the configured group may be assigned.' }
        $jobPath = "servicePrincipals/$($sp.id)/synchronization/jobs/$($state.jobId)"
        $liveSchema = Invoke-MtoGraph -Method GET -Path "$jobPath/schema"
        if (-not (Test-MtoGroupSyncSchema -Schema $liveSchema)) {
            throw 'Mapping drift. Verify enabled users/groups and Guest ObjectAddOnly mapping before starting.'
        }
        if ($PSCmdlet.ShouldProcess("$sourceId -> $targetId", 'Enforce assigned-only scope and start ongoing group/user/membership provisioning')) {
            $null = Invoke-MtoGraph -Method PUT -Path "servicePrincipals/$($sp.id)/synchronization/secrets" -Body @{
                value = @(
                    @{ key = 'AuthenticationType'; value = 'SyncPolicy' }
                    @{ key = 'CompanyId'; value = $targetId }
                    @{ key = 'SyncAll'; value = 'false' }
                )
            }
            $null = Invoke-MtoGraph -Method POST -Path "$jobPath/start"
        }
    }
    'Pause' {
        $sp = Assert-OwnedApplication
        if (-not $sp -or -not $state.jobId) { throw 'Owned provisioning job missing.' }
        if ($PSCmdlet.ShouldProcess($state.jobId, 'Pause provisioning (does NOT revoke existing target access)')) {
            $null = Invoke-MtoGraph -Method POST -Path "servicePrincipals/$($sp.id)/synchronization/jobs/$($state.jobId)/pause"
        }
    }
    'Remove' {
        if (-not $state.servicePrincipalId -and -not $state.groupId) { throw 'No toolkit-owned relationship recorded.' }
        $sp = if ($state.servicePrincipalId) { Assert-OwnedApplication } else { $null }
        $group = if ($state.groupId -and $state.groupCreated -and $RemoveEmptySourceGroup) { Get-SourceGroup } else { $null }
        if ($group -and @(Get-MtoGraphCollection -Path "groups/$($group.id)/members?`$select=id").Count) {
            throw 'Will not delete a populated source group. Preserve it or explicitly empty it after reviewing all uses.'
        }
        if ($PSCmdlet.ShouldProcess("$sourceId -> $targetId", 'Remove ONLY owned source sync application; optionally empty owned source group. Target accounts/policies/access remain')) {
            if ($sp) {
                if ($state.jobId) { $null = Invoke-MtoGraph -Method POST -Path "servicePrincipals/$($sp.id)/synchronization/jobs/$($state.jobId)/pause" }
                $null = Invoke-MtoGraph -Method DELETE -Path "servicePrincipals/$($sp.id)"
            }
            if ($state.applicationId -and (Get-MtoOptionalGraph -Path "applications/$($state.applicationId)")) {
                $null = Invoke-MtoGraph -Method DELETE -Path "applications/$($state.applicationId)"
            }
            $state.servicePrincipalId = $null
            $state.applicationId = $null
            $state.jobId = $null
            $state.assignmentId = $null
            $state.configured = $false
            if ($group) {
                $null = Invoke-MtoGraph -Method DELETE -Path "groups/$($group.id)"
                $state.groupId = $null
                $state.groupCreated = $false
            }
            Save-Checkpoint
        }
    }
}
} finally {
    if ($stateLock) { $stateLock.Dispose() }
}
