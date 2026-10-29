#Requires -Version 7.2
<#
.SYNOPSIS
Plans, applies, or removes a state-tracked resource-group Azure Lighthouse delegation.
.DESCRIPTION
Plan and -WhatIf are offline. Apply/Remove require an explicitly selected customer
Az context. This script never signs in, changes context, or registers providers.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Apply', 'Remove')]
    [string] $Mode,
    [Parameter(Mandatory)]
    [string] $ConfigPath,
    [Parameter(Mandatory)]
    [guid] $ManagedTenantId,
    [ValidatePattern('^[a-z0-9]+$')]
    [string] $DeploymentLocation = 'eastus'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\MtoToolkit.psm1') -ErrorAction Stop
$reader = '8d289c81-5878-46d4-8554-54e1e3d8b5cb'
$allowedRoles = @($reader, '3e150937-b8fe-4cfb-8069-0eaf05ecd056', 'ab8e14d6-4a74-4a29-9ba8-549422addade')

function ConvertTo-RequiredGuid([object] $Value, [string] $Label) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse([string] $Value, [ref] $parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Label must be a nonempty GUID."
    }
    $parsed.ToString()
}

function Get-DeterministicGuid([string] $Text) {
    $hash = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())) }
    finally { $hash.Dispose() }
    ([guid]::new([byte[]] $bytes[0..15])).ToString()
}

function Get-AuthorizationKey([object[]] $Items) {
    @($Items | ForEach-Object {
        if ($_.Contains('delegatedRoleDefinitionIds') -and $_.delegatedRoleDefinitionIds) {
            throw 'Delegated roles are not supported.'
        }
        $principal = ConvertTo-RequiredGuid $_.principalId 'authorization principalId'
        $role = if ($_.Contains('roleDefinitionId') -and $_.roleDefinitionId) {
            ConvertTo-RequiredGuid $_.roleDefinitionId 'authorization roleDefinitionId'
        } else { $reader }
        if ($role -notin $allowedRoles) { throw 'Only Microsoft Sentinel Reader, Responder, and Contributor roles are allowed.' }
        "$principal|$role"
    } | Sort-Object -Unique) -join ';'
}

function Assert-CustomerContext {
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or [string] $context.Tenant.Id -ne $customerId -or
        [string] $context.Subscription.Id -ne $subscriptionId) {
        throw 'Az context must match the configured managed tenant AND subscription. Select it explicitly and retry.'
    }
    $context
}

function Get-RemoteResource([string] $Id, [object] $Context) {
    try {
        $response = Invoke-AzRestMethod -Path "${Id}?api-version=2022-10-01" -Method GET -DefaultProfile $Context -ErrorAction Stop
    } catch {
        $status = $_.Exception.PSObject.Properties['Response']
        if ($status -and $status.Value -and [int] $status.Value.StatusCode -eq 404) { return $null }
        throw
    }
    if ([int] $response.StatusCode -eq 404) { return $null }
    if ([int] $response.StatusCode -ne 200) { throw "Read failed for $Id (HTTP $($response.StatusCode))." }
    $response.Content | ConvertFrom-Json -AsHashtable
}

function Assert-OwnedResource([object] $Definition, [object] $Assignment, [object] $State) {
    if ($Definition) {
        if ($Definition.id -ine $definitionId -or
            $Definition.properties.managedByTenantId -ine $managerId -or
            $Definition.properties.description -cne $State.ownershipMarker -or
            $Definition.properties.registrationDefinitionName -cne "m365-mto-toolkit-$definitionName" -or
            (Get-AuthorizationKey @($Definition.properties.authorizations)) -cne $authorizationKey) {
            throw 'Registration definition identity/ownership/authorizations mismatch; refusing any write.'
        }
        if (($Definition.properties.Contains('eligibleAuthorizations') -and $Definition.properties.eligibleAuthorizations) -or
            ($Definition.Contains('plan') -and $Definition.plan)) {
            throw 'Unexpected eligible authorizations or marketplace plan; refusing any write.'
        }
    }
    if ($Assignment -and ($Assignment.id -ine $assignmentId -or
        $Assignment.properties.registrationDefinitionId -ine $definitionId -or -not $Definition)) {
        throw 'Registration assignment identity/reference mismatch or definition missing; refusing any write.'
    }
}

function Save-NewState([object] $Value) {
    $stream = [IO.File]::Open($statePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 20))
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Invoke-OwnedResourceDeletion([string] $Id) {
    $context = Assert-CustomerContext
    $response = Invoke-AzRestMethod -Path "${Id}?api-version=2022-10-01" -Method DELETE -DefaultProfile $context -ErrorAction Stop
    if ([int] $response.StatusCode -notin @(200, 202, 204, 404)) {
        throw "Deletion failed for $Id (HTTP $($response.StatusCode)); state retained."
    }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (-not (Get-RemoteResource $Id $context)) { return }
        Start-Sleep -Seconds 2
    }
    throw "Deletion not confirmed for $Id; state retained. Retry Remove."
}

$config = Read-MtoConfiguration -Path $ConfigPath | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable
$managerId = ConvertTo-RequiredGuid $config.managingTenant.tenantId 'managingTenant.tenantId'
$customerId = ConvertTo-RequiredGuid $ManagedTenantId 'ManagedTenantId'
if ($managerId -eq $customerId) { throw 'Managing and managed tenants must be different.' }
$tenants = @($config.managedTenants | Where-Object {
    (ConvertTo-RequiredGuid $_.tenantId 'managed tenantId') -eq $customerId
})
if ($tenants.Count -ne 1) { throw 'ManagedTenantId must match exactly one managedTenants entry.' }
$tenant = $tenants[0]
$subscriptionId = ConvertTo-RequiredGuid $tenant.azure.subscriptionId 'azure.subscriptionId'
$resourceGroup = [string] $tenant.azure.resourceGroup
if ($resourceGroup -notmatch '^[\p{L}\p{N}_().-]{1,90}$' -or $resourceGroup.EndsWith('.')) {
    throw 'azure.resourceGroup must be an existing valid resource group name.'
}
if ([string]::IsNullOrWhiteSpace([string] $tenant.azure.workspaceName)) {
    throw 'azure.workspaceName is required for operator verification; no workspace will be created.'
}
$rawAuthorizations = @($tenant.lighthouse.authorizations)
if ($rawAuthorizations.Count -eq 0) { throw 'At least one Lighthouse authorization is required.' }
foreach ($authorization in $rawAuthorizations) {
    if ($authorization.Keys | Where-Object { $_ -notin @('principalId', 'roleDefinitionId', 'principalIdDisplayName') }) {
        throw 'Unexpected authorization properties.'
    }
}
$authorizationKey = Get-AuthorizationKey $rawAuthorizations
$authorizations = @($rawAuthorizations | ForEach-Object {
    $item = @{
        principalId = ConvertTo-RequiredGuid $_.principalId 'authorization principalId'
        roleDefinitionId = if ($_.Contains('roleDefinitionId') -and $_.roleDefinitionId) { ([guid] $_.roleDefinitionId).ToString() } else { $reader }
    }
    if ($_.Contains('principalIdDisplayName') -and $_.principalIdDisplayName) {
        $item.principalIdDisplayName = [string] $_.principalIdDisplayName
    }
    $item
})
if ($authorizations.Count -ne $authorizationKey.Split(';').Count) { throw 'Duplicate Lighthouse authorizations are not allowed.' }
$scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
$definitionName = Get-DeterministicGuid "m365-mto-toolkit|definition|$customerId|$managerId|$scope"
$assignmentName = Get-DeterministicGuid "m365-mto-toolkit|assignment|$customerId|$managerId|$scope"
$definitionId = "/subscriptions/$subscriptionId/providers/Microsoft.ManagedServices/registrationDefinitions/$definitionName"
$assignmentId = "$scope/providers/Microsoft.ManagedServices/registrationAssignments/$assignmentName"
$statePath = Join-Path $root ".local\lighthouse\$assignmentName.json"
$state = $null
$originalState = $null
if (Test-Path -LiteralPath $statePath) {
    $originalState = Get-Content -LiteralPath $statePath -Raw
    $state = $originalState | ConvertFrom-Json -AsHashtable
    if ($state.schemaVersion -ne 1 -or $state.tool -cne 'm365-mto-toolkit/lighthouse' -or
        $state.managingTenantId -ine $managerId -or $state.managedTenantId -ine $customerId -or
        $state.scope -ine $scope -or $state.definitionId -ine $definitionId -or
        $state.assignmentId -ine $assignmentId -or $state.authorizationKey -cne $authorizationKey -or
        $state.ownershipMarker -notmatch '^m365-mto-toolkit/lighthouse:[0-9a-f]{32}$') {
        throw 'Local Lighthouse state does not match the requested identities, scope, or authorizations.'
    }
}
$plan = [pscustomobject] @{
    Mode = $Mode; ManagedTenantId = $customerId; ManagingTenantId = $managerId
    Scope = $scope; WorkspaceName = $tenant.azure.workspaceName
    DefinitionId = $definitionId; AssignmentId = $assignmentId
    Authorizations = $authorizations; StatePath = $statePath; HasState = [bool] $state
    TemplateFile = Join-Path $root 'templates\lighthouse-rg.json'
    DeploymentLocation = $DeploymentLocation
}
if ($Mode -eq 'Plan') { return $plan }
if ($Mode -eq 'Remove' -and -not $state) {
    throw 'No toolkit ownership state exists; refusing discovery, adoption, or removal.'
}
if (-not $PSCmdlet.ShouldProcess("$customerId :: $scope :: $assignmentId",
    "$Mode toolkit Lighthouse delegation (definition $definitionId; no workspace/RG changes)")) {
    return $plan
}

# Serialize local operations; the remote ownership marker also guards recovery.
[IO.Directory]::CreateDirectory((Split-Path $statePath -Parent)) | Out-Null
$lock = [IO.File]::Open("$statePath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    if ($state -and (-not (Test-Path -LiteralPath $statePath) -or
        (Get-Content -LiteralPath $statePath -Raw) -cne $originalState)) {
        throw 'Ownership state changed concurrently; retry with fresh state.'
    }
    $context = Assert-CustomerContext
    $definition = Get-RemoteResource $definitionId $context
    $assignment = Get-RemoteResource $assignmentId $context
    if (-not $state -and ($definition -or $assignment)) {
        throw 'A registration resource already exists without ownership state; refusing to overwrite or adopt it.'
    }
    if ($state) { Assert-OwnedResource $definition $assignment $state }
    if ($Mode -eq 'Apply') {
        if ($state -and $definition -and $assignment) {
            if ($definition.properties.provisioningState -ne 'Succeeded' -or
                $assignment.properties.provisioningState -ne 'Succeeded') {
                throw 'Existing registration resources have not succeeded; inspect them manually before retrying.'
            }
            return $plan
        }
        if (-not $state) {
            $state = @{
                schemaVersion = 1; tool = 'm365-mto-toolkit/lighthouse'
                managingTenantId = $managerId; managedTenantId = $customerId; scope = $scope
                definitionId = $definitionId; assignmentId = $assignmentId
                authorizationKey = $authorizationKey
                ownershipMarker = "m365-mto-toolkit/lighthouse:$([guid]::NewGuid().ToString('N'))"
            }
            Save-NewState $state
        }
        $parameters = @{
            managedByTenantId = $managerId; resourceGroupName = $resourceGroup
            registrationDefinitionName = $definitionName; registrationAssignmentName = $assignmentName
            ownershipMarker = $state.ownershipMarker; authorizations = $authorizations
        }
        $context = Assert-CustomerContext
        New-AzSubscriptionDeployment -Name "mto-lighthouse-$assignmentName" -Location $DeploymentLocation `
            -TemplateFile $plan.TemplateFile -TemplateParameterObject $parameters `
            -DefaultProfile $context -Confirm:$false -ErrorAction Stop | Out-Null
        $definition = Get-RemoteResource $definitionId $context
        $assignment = Get-RemoteResource $assignmentId $context
        Assert-OwnedResource $definition $assignment $state
        if (-not $definition -or -not $assignment -or
            $definition.properties.provisioningState -ne 'Succeeded' -or
            $assignment.properties.provisioningState -ne 'Succeeded') {
            throw 'Deployment not verified as successful; ownership state retained for recovery.'
        }
    } else {
        if ($assignment) { Invoke-OwnedResourceDeletion $assignmentId }
        $context = Assert-CustomerContext
        $definition = Get-RemoteResource $definitionId $context
        Assert-OwnedResource $definition $null $state
        if ($definition) { Invoke-OwnedResourceDeletion $definitionId }
        Remove-Item -LiteralPath $statePath -Force -Confirm:$false
    }
    $plan
} finally {
    $lock.Dispose()
}
