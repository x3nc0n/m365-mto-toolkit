#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-MtoConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $json = Get-Content -LiteralPath $Path -Raw
    $schema = Join-Path $PSScriptRoot '..\config\configuration.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schema -ErrorAction Stop)) {
        throw 'Configuration does not match configuration.schema.json.'
    }
    $config = $json | ConvertFrom-Json -AsHashtable
    $seen = @($config.managingTenant.tenantId)
    foreach ($tenant in $config.managedTenants) {
        if ($tenant.tenantId -in $seen) { throw 'Tenant IDs must be unique; source and target must differ.' }
        $seen += $tenant.tenantId
        if ($tenant.sourceGroup.create -eq [bool]$tenant.sourceGroup.objectId) {
            throw 'Choose create=true with objectId=null OR create=false with an existing group objectId.'
        }
    }
    return $config
}

function Assert-MtoGraphContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $TenantId -or $context.AuthType -ne 'Delegated') {
        throw "Connect-MgGraph with delegated interactive authentication to tenant $TenantId."
    }
}

function Assert-MtoAzContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$SubscriptionId)
    $context = Get-AzContext
    if (-not $context -or $context.Tenant.Id -ne $TenantId -or $context.Subscription.Id -ne $SubscriptionId) {
        throw "Connect-AzAccount and select subscription $SubscriptionId in tenant $TenantId."
    }
}

function Invoke-MtoGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body
    )
    if ($Path -match '^https?://' -and $Path -notmatch '^https://graph\.microsoft\.com/v1\.0/') {
        throw 'Only Microsoft Graph v1.0 URLs are allowed.'
    }
    $uri = if ($Path.StartsWith('https://graph.microsoft.com/v1.0/')) { $Path } else { "https://graph.microsoft.com/v1.0/$($Path.TrimStart('/'))" }
    $parameters = @{ Method = $Method; Uri = $uri; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 100 -Compress
        $parameters.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @parameters
}

function Get-MtoGraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $next = $Path
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($next) {
        if (-not $visited.Add($next)) { throw 'Graph returned a pagination loop.' }
        $page = Invoke-MtoGraph -Method GET -Path $next
        if (-not $page.ContainsKey('value')) { throw 'Expected a Graph collection.' }
        foreach ($item in $page.value) { $item }
        $next = $page['@odata.nextLink']
    }
}

function Get-MtoOptionalGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    try { Invoke-MtoGraph -Method GET -Path $Path }
    catch {
        # Only a typed HTTP 404 is absence, never an authentication/authorization failure.
        $response = $_.Exception.PSObject.Properties['Response']
        if ($response -and $response.Value -and [int]$response.Value.StatusCode -eq 404) { return $null }
        throw
    }
}

function Read-MtoState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$SourceTenantId, [string]$TargetTenantId)
    if (Test-Path -LiteralPath $Path) {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
        if ($state.sourceTenantId -ne $SourceTenantId -or $state.targetTenantId -ne $TargetTenantId -or $state.version -ne 1) {
            throw 'State ownership/tenant mismatch. Do not reuse state across relationships.'
        }
        return $state
    }
    return @{
        version = 1; sourceTenantId = $SourceTenantId; targetTenantId = $TargetTenantId
        groupId = $null; groupCreated = $false; servicePrincipalId = $null; applicationId = $null
        jobId = $null; assignmentId = $null; configured = $false
        ownershipToken = [guid]::NewGuid().ToString(); pendingOperation = $null
    }
}

function Save-MtoState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State, [Parameter(Mandatory)][string]$Path)
    $directory = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $directory -Force
    $temporary = "$Path.tmp"
    $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function ConvertTo-MtoGroupSyncSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Schema)
    $mappings = @($Schema.synchronizationRules | ForEach-Object { $_.objectMappings })
    $users = @($mappings | Where-Object { $_.sourceObjectName -eq 'User' -and $_.targetObjectName -eq 'User' })
    $groups = @($mappings | Where-Object { $_.sourceObjectName -eq 'Group' -and $_.targetObjectName -eq 'Group' })
    if ($users.Count -ne 1 -or $groups.Count -ne 1) {
        throw 'Expected one User and one Group mapping. Review Microsoft template/feature availability; no schema was written.'
    }
    $types = @($users[0].attributeMappings | Where-Object { $_.targetAttributeName -eq 'userType' })
    $members = @($groups[0].attributeMappings | Where-Object { $_.targetAttributeName -eq 'members' })
    if ($types.Count -ne 1 -or $members.Count -ne 1) { throw 'Expected userType and group members mappings.' }
    $types[0].source = @{ type = 'Constant'; name = 'Guest'; expression = '"Guest"'; parameters = @() }
    $types[0].flowType = 'ObjectAddOnly'
    $users[0].enabled = $true
    $groups[0].enabled = $true
    $null = $Schema.Remove('@odata.context')
    return $Schema
}

function Get-MtoSentinelRole {
    [CmdletBinding()]
    param([ValidateSet('Reader','Responder','Contributor')][string]$RoleProfile)
    switch ($RoleProfile) {
        'Reader' { '8d289c81-5878-46d4-8554-54e1e3d8b5cb' }
        'Responder' { '3e150937-b8fe-4cfb-8069-0eaf05ecd056' }
        'Contributor' { 'ab8e14d6-4a74-4a29-9ba8-549422addade' }
    }
}

function Test-MtoGroupSyncSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Schema)
    $mappings = @($Schema.synchronizationRules | ForEach-Object { $_.objectMappings })
    $users = @($mappings | Where-Object { $_.sourceObjectName -eq 'User' -and $_.targetObjectName -eq 'User' })
    $groups = @($mappings | Where-Object { $_.sourceObjectName -eq 'Group' -and $_.targetObjectName -eq 'Group' })
    if ($users.Count -ne 1 -or $groups.Count -ne 1 -or -not $users[0].enabled -or -not $groups[0].enabled) { return $false }
    $types = @($users[0].attributeMappings | Where-Object { $_.targetAttributeName -eq 'userType' })
    $members = @($groups[0].attributeMappings | Where-Object { $_.targetAttributeName -eq 'members' })
    return ($types.Count -eq 1 -and $members.Count -eq 1 -and
        $types[0].flowType -eq 'ObjectAddOnly' -and $types[0].source.type -eq 'Constant' -and
        $types[0].source.name -eq 'Guest')
}

function Enter-MtoStateLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    try {
        return [System.IO.File]::Open("$Path.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        throw 'Relationship state is locked or unavailable. Do not run mutation phases concurrently.'
    }
}

Export-ModuleMember -Function Read-MtoConfiguration, Assert-MtoGraphContext, Assert-MtoAzContext, Invoke-MtoGraph, Get-MtoGraphCollection, Get-MtoOptionalGraph, Read-MtoState, Save-MtoState, ConvertTo-MtoGroupSyncSchema, Test-MtoGroupSyncSchema, Get-MtoSentinelRole, Enter-MtoStateLock
