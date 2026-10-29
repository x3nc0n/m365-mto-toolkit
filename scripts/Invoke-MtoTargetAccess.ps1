#requires -Version 7.2
<#
.SYNOPSIS
Plans, grants or removes one owned workspace-scoped Sentinel role for the target group.
.DESCRIPTION
This is native Azure RBAC, not Defender Unified RBAC and not Lighthouse.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][guid]$ManagedTenantId,
    [ValidateSet('Plan','Apply','Remove')][string]$Mode = 'Plan',
    [string]$StateDirectory = (Join-Path $PSScriptRoot '..\.local')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\MtoToolkit.psm1')
$config = Read-MtoConfiguration -Path $ConfigPath
$targets = @($config.managedTenants | Where-Object { $_.tenantId -eq $ManagedTenantId.ToString() })
if ($targets.Count -ne 1) { throw 'Unknown ManagedTenantId.' }
$target = $targets[0]
$subscriptionId = $target.azure.subscriptionId
$scope = "/subscriptions/$subscriptionId/resourceGroups/$($target.azure.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.azure.workspaceName)"
$roleId = Get-MtoSentinelRole -RoleProfile $target.authorization.profile
$groupId = $target.authorization.targetGroupObjectId
$statePath = Join-Path $StateDirectory "access-$($config.managingTenant.tenantId)-$($target.tenantId).json"
if ($Mode -eq 'Plan') {
    [pscustomobject]@{
        Evidence = 'LocalPlan'; Scope = $scope; TargetGroupId = $groupId; SentinelRole = $target.authorization.profile
        DefenderUnifiedRbac = 'Manual: assign the synced child group in security.microsoft.com; do not assign an Entra directory role to it.'
    }
    return
}
Assert-MtoAzContext -TenantId $target.tenantId -SubscriptionId $subscriptionId
Assert-MtoGraphContext -TenantId $target.tenantId
$stateLock = if (-not $WhatIfPreference) { Enter-MtoStateLock -Path $statePath } else { $null }
try {
if (-not $groupId) { throw 'Set the actual targetGroupObjectId verified from provisioning logs, never the source group ID.' }
if ($groupId -eq $target.sourceGroup.objectId) { throw 'Target group cannot be the source group object ID.' }
$group = Invoke-MtoGraph -Method GET -Path "groups/$groupId"
if (-not $group.securityEnabled -or $group.mailEnabled -or 'DynamicMembership' -in $group.groupTypes -or $group.isAssignableToRole) {
    throw 'Expected the synced static, non-role-assignable target security group.'
}
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
if ($state -and ($state.sourceTenantId -ne $config.managingTenant.tenantId -or
    $state.targetTenantId -ne $target.tenantId -or $state.scope -ne $scope -or
    $state.groupId -ne $groupId -or $state.roleId -ne $roleId)) {
    throw 'State/config scope, principal or role changed. Remove the old recorded assignment before changing profiles.'
}

function Invoke-AccessArm {
    param([string]$Method, [string]$Path, [hashtable]$Body)
    $parameters = @{ Method = $Method; Path = $Path; ErrorAction = 'Stop' }
    if ($Body) { $parameters.Payload = $Body | ConvertTo-Json -Depth 10 -Compress }
    $result = Invoke-AzRestMethod @parameters
    if ($result.StatusCode -eq 404 -and $Method -eq 'GET') { return $null }
    if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        throw "Azure RBAC $Method failed with HTTP $($result.StatusCode)."
    }
    if ($result.Content) { return ($result.Content | ConvertFrom-Json -AsHashtable) }
}

$null = Invoke-AccessArm -Method GET -Path "${scope}?api-version=2022-10-01"
$roleResourceId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/$roleId"
if ($Mode -eq 'Apply') {
    if (-not $state) {
        $existing = @(Get-AzRoleAssignment -ObjectId $groupId -Scope $scope -RoleDefinitionId $roleId -ErrorAction Stop |
            Where-Object { $_.Scope -eq $scope })
        if ($existing.Count) {
            [pscustomobject]@{ Evidence = 'ApiVerified'; Status = 'PreexistingPreserved'; Scope = $scope }
            return
        }
        $state = @{
            version = 1; sourceTenantId = $config.managingTenant.tenantId; targetTenantId = $target.tenantId
            scope = $scope; groupId = $groupId; roleId = $roleId; assignmentId = [guid]::NewGuid().ToString()
            status = 'PendingCreate'
        }
    }
    $path = "$scope/providers/Microsoft.Authorization/roleAssignments/$($state.assignmentId)?api-version=2022-04-01"
    $current = Invoke-AccessArm -Method GET -Path $path
    if ($current) {
        if ($current.properties.principalId -ne $groupId -or $current.properties.roleDefinitionId -ne $roleResourceId) {
            throw 'Role assignment ownership collision.'
        }
        if ($state.status -ne 'Created') { throw 'Pending creation requires manual recovery; do not adopt an unverified assignment.' }
        [pscustomobject]@{ Evidence = 'ApiVerified'; Status = 'AlreadyAssigned'; Scope = $scope }
        return
    }
    if ($PSCmdlet.ShouldProcess("$groupId / $scope", "Grant workspace-scoped Sentinel $($target.authorization.profile)")) {
        Save-MtoState -State $state -Path $statePath
        $null = Invoke-AccessArm -Method PUT -Path $path -Body @{
            properties = @{ principalId = $groupId; principalType = 'Group'; roleDefinitionId = $roleResourceId }
        }
        $state.status = 'Created'
        Save-MtoState -State $state -Path $statePath
    }
} else {
    if (-not $state -or $state.status -ne 'Created') { throw 'No verified toolkit-created assignment recorded; refusing removal.' }
    $path = "$scope/providers/Microsoft.Authorization/roleAssignments/$($state.assignmentId)?api-version=2022-04-01"
    $current = Invoke-AccessArm -Method GET -Path $path
    if ($current -and ($current.properties.principalId -ne $groupId -or $current.properties.roleDefinitionId -ne $roleResourceId)) {
        throw 'Role assignment ownership check failed.'
    }
    if ($PSCmdlet.ShouldProcess($state.assignmentId, 'Remove ONLY the recorded toolkit-created workspace role assignment')) {
        if ($current) { $null = Invoke-AccessArm -Method DELETE -Path $path }
        Remove-Item -LiteralPath $statePath
    }
}
} finally {
    if ($stateLock) { $stateLock.Dispose() }
}
