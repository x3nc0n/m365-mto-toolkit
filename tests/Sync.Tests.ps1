BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src\MtoToolkit.psm1')
    function global:Get-MgContext { throw 'Offline stub must be mocked.' }
    function global:Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Body, $ContentType)
        throw 'Offline stub must be mocked.'
    }
}

Describe 'Source synchronization mutation boundaries (offline mocks)' {
    BeforeEach {
        $script:config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $script:sourceId = $script:config.managingTenant.tenantId
        $script:targetId = $script:config.managedTenants[0].tenantId
        $script:groupId = '55555555-5555-4555-8555-555555555555'
        $script:directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory $script:directory
        $script:configPath = Join-Path $script:directory 'configuration.json'
        $script:config | ConvertTo-Json -Depth 30 | Set-Content $script:configPath
        $script:parameters = @{
            ConfigPath = $script:configPath; ManagedTenantId = $script:targetId
            StateDirectory = $script:directory; Mode = 'Apply'; Confirm = $false
        }
        Mock Get-MgContext { @{ TenantId = '11111111-1111-4111-8111-111111111111'; AuthType = 'Delegated' } } -ModuleName MtoToolkit
        Mock Invoke-MgGraphRequest { throw "Unexpected offline request: $Method $Uri" } -ModuleName MtoToolkit
    }
    It 'SourceGroup WhatIf sends no writes and persists no ownership state' {
        Mock Invoke-MgGraphRequest { @{ value = @() } } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'GET' }
        & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase SourceGroup -WhatIf
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -ne 'GET' }
        @(Get-ChildItem $script:directory -Filter 'sync-*').Count | Should -Be 0
    }
    It 'creates one group, records its ID and makes rerun read-only' {
        Mock Invoke-MgGraphRequest { @{ value = @() } } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*groups?*' }
        Mock Invoke-MgGraphRequest {
            $payload = $Body | ConvertFrom-Json -AsHashtable
            @{ id = '55555555-5555-4555-8555-555555555555'; description = $payload.description }
        } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/groups' }
        $result = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase SourceGroup
        $result.GroupId | Should -Be $script:groupId
        $stateFile = Get-ChildItem $script:directory -Filter 'sync-*.json'
        $state = Get-Content $stateFile.FullName -Raw | ConvertFrom-Json -AsHashtable
        $script:marker = "MtoToolkit:$($state.ownershipToken)"
        Mock Invoke-MgGraphRequest -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/groups/5555*' } -MockWith {
            $saved = Get-Content $stateFile.FullName -Raw | ConvertFrom-Json -AsHashtable
            @{ id = $saved.groupId; securityEnabled = $true; mailEnabled = $false; groupTypes = @(); description = "MtoToolkit:$($saved.ownershipToken)" }
        }
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase SourceGroup
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }
    It 'does not adopt a name collision' {
        Mock Invoke-MgGraphRequest { @{ value = @(@{ id = 'preexisting' }) } } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'GET' }
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase SourceGroup } | Should -Throw '*exists*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }
    It 'stops Configure before cloud requests when license and consent gates are closed' {
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase Configure } | Should -Throw '*licensing*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
    It 'stops Start before cloud requests unless explicitly approved' {
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase Start } | Should -Throw '*Start requires*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
    It 'refuses a pending creation instead of duplicating cloud objects' {
        $statePath = Join-Path $script:directory "sync-$script:sourceId-$script:targetId.json"
        $state = Read-MtoState $statePath $script:sourceId $script:targetId
        $state.pendingOperation = 'InstantiateApplication'
        Save-MtoState $state $statePath
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase Configure } | Should -Throw '*Unresolved operation*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
    It 'retains a pending journal if creation fails' {
        Mock Invoke-MgGraphRequest { @{ value = @() } } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-MgGraphRequest { throw 'service unavailable' } -ModuleName MtoToolkit -ParameterFilter { $Method -eq 'POST' }
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase SourceGroup } | Should -Throw '*unavailable*'
        $statePath = Join-Path $script:directory "sync-$script:sourceId-$script:targetId.json"
        (Read-MtoState $statePath $script:sourceId $script:targetId).pendingOperation | Should -Be 'CreateSourceGroup'
    }
    It 'refuses removal without ownership records' {
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @script:parameters -Phase Remove } | Should -Throw '*No toolkit-owned*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
}

Describe 'Dedicated group/user job lifecycle (offline mocks)' {
    BeforeEach {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $targetId = $config.managedTenants[0].tenantId
        $sourceId = $config.managingTenant.tenantId
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory $directory
        $configPath = Join-Path $directory 'configuration.json'
        $config.managedTenants[0].attestations.governanceOrSuiteForEverySyncedUser = $true
        $config.managedTenants[0].attestations.targetGroupSyncEnabled = $true
        $config.managedTenants[0].attestations.targetConsentApproved = $true
        $config.managedTenants[0].synchronization.reviewedMatchingAndLifecycle = $true
        $config.managedTenants[0].synchronization.approveStart = $true
        $config | ConvertTo-Json -Depth 30 | Set-Content $configPath
        $statePath = Join-Path $directory "sync-$sourceId-$targetId.json"
        $state = Read-MtoState $statePath $sourceId $targetId
        $state.groupId = '55555555-5555-4555-8555-555555555555'
        Save-MtoState $state $statePath
        $parameters = @{ ConfigPath = $configPath; ManagedTenantId = $targetId; StateDirectory = $directory; Mode = 'Apply'; Confirm = $false }
        $fixture = @{
            Name = "MTO-$targetId-$($state.ownershipToken)"; Assignments = @(); Started = $false
            CredentialWrites = @(); Nested = $false; SpPresent = $false; ApplicationPresent = $false
            Schema = @{
                synchronizationRules = @(@{
                    objectMappings = @(
                        @{
                            sourceObjectName = 'User'; targetObjectName = 'User'; enabled = $true
                            attributeMappings = @(@{ targetAttributeName = 'userType'; flowType = 'ObjectAddOnly'; source = @{ type = 'Constant'; name = 'Member' } })
                        },
                        @{
                            sourceObjectName = 'Group'; targetObjectName = 'Group'; enabled = $false
                            attributeMappings = @(@{ targetAttributeName = 'members'; source = @{ type = 'Attribute'; name = 'members' } })
                        }
                    )
                })
            }
        }
        Mock Get-MgContext { @{ TenantId = '11111111-1111-4111-8111-111111111111'; AuthType = 'Delegated' } } -ModuleName MtoToolkit
        Mock Invoke-MgGraphRequest -ModuleName MtoToolkit {
            param($Method, $Uri, $Body)
            $path = $Uri.Replace('https://graph.microsoft.com/v1.0/','')
            $payload = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
            switch -Regex ("$Method $path") {
                '^GET groups/[^/]+$' {
                    return @{ id = '55555555-5555-4555-8555-555555555555'; securityEnabled = $true; mailEnabled = $false; groupTypes = @() }
                }
                '^GET groups/.+/members\?' {
                    $type = if ($fixture.Nested) { '#microsoft.graph.group' } else { '#microsoft.graph.user' }
                    return @{ value = @(@{ id = 'user'; '@odata.type' = $type }) }
                }
                '^GET users/' { return @{ id = 'user'; userType = 'Member'; creationType = $null; externalUserState = $null } }
                '^GET policies/' { return @{ automaticUserConsentSettings = @{ outboundAllowed = $true } } }
                '^GET servicePrincipals\?' { return @{ value = @() } }
                '^POST applicationTemplates/' {
                    $fixture.SpPresent = $true
                    $fixture.ApplicationPresent = $true
                    return @{ servicePrincipal = @{ id = 'sp' }; application = @{ id = 'app' } }
                }
                '^GET servicePrincipals/sp$' {
                    return @{
                        id = 'sp'; appId = 'client'; displayName = $fixture.Name
                        applicationTemplateId = '518e5f48-1fc8-4c48-9387-9fdf28b0dfe7'
                        appRoles = @(@{ id = 'role'; isEnabled = $true; allowedMemberTypes = @('User') })
                    }
                }
                '^GET applications/app$' { return @{ id = 'app'; appId = 'client'; displayName = $fixture.Name } }
                '^GET servicePrincipals/sp/synchronization/jobs$' { return @{ value = @() } }
                '^POST servicePrincipals/sp/synchronization/jobs$' { return @{ id = 'job' } }
                '^GET servicePrincipals/sp/synchronization/jobs/job$' { return @{ id = 'job'; templateId = 'Azure2Azure'; schedule = @{ state = 'Disabled' } } }
                '^POST .+/validateCredentials$' { return }
                '^PUT .+/synchronization/secrets$' { $fixture.CredentialWrites += ,$payload; return }
                '^GET .+/schema$' { return ($fixture.Schema | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable) }
                '^PUT .+/schema$' { $fixture.Schema = $payload; return }
                '^GET .+/appRoleAssignedTo$' { return @{ value = $fixture.Assignments } }
                '^POST .+/appRoleAssignedTo$' {
                    $fixture.Assignments = @(@{ id = 'assignment'; principalId = $payload.principalId })
                    return @{ id = 'assignment' }
                }
                '^POST .+/start$' { $fixture.Started = $true; return }
                '^POST .+/pause$' { return }
                '^DELETE servicePrincipals/sp$' { $fixture.SpPresent = $false; return }
                '^DELETE applications/app$' { $fixture.ApplicationPresent = $false; return }
                default { throw "Unexpected offline request: $Method $path" }
            }
        }
    }
    It 'configures a paused group/user job with assigned-only scope and idempotent rerun' {
        $result = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        $result.Status | Should -Be 'ConfiguredPaused'
        $saved = Read-MtoState $statePath $sourceId $targetId
        $saved.configured | Should -BeTrue
        $saved.jobId | Should -Be 'job'
        $fixture.Started | Should -BeFalse
        $fixture.Schema.synchronizationRules[0].objectMappings[1].enabled | Should -BeTrue
        $fixture.Schema.synchronizationRules[0].objectMappings[0].attributeMappings[0].source.name | Should -Be 'Guest'
        $fixture.Schema.synchronizationRules[0].objectMappings[0].attributeMappings[0].flowType | Should -Be 'ObjectAddOnly'
        @($fixture.CredentialWrites[0].value | Where-Object { $_.key -eq 'SyncAll' })[0].value | Should -Be 'false'
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/instantiate' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/synchronization/jobs' }
    }
    It 'Configure WhatIf makes no write requests and leaves ownership state unchanged' {
        $before = Get-Content $statePath -Raw
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure -WhatIf
        Get-Content $statePath -Raw | Should -Be $before
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }
    It 'starts only after configuring and reasserts assigned-only target credentials' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Start
        $fixture.Started | Should -BeTrue
        $fixture.CredentialWrites.Count | Should -Be 2
        @($fixture.CredentialWrites[1].value | Where-Object { $_.key -eq 'CompanyId' })[0].value | Should -Be $targetId
        @($fixture.CredentialWrites[1].value | Where-Object { $_.key -eq 'SyncAll' })[0].value | Should -Be 'false'
    }
    It 'rejects mapping drift before starting' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        $fixture.Schema.synchronizationRules[0].objectMappings[0].attributeMappings[0].flowType = 'Always'
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Start } | Should -Throw '*Mapping drift*'
        $fixture.Started | Should -BeFalse
    }
    It 'rejects extra assignments before starting' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        $fixture.Assignments += @{ principalId = 'unintended-user' }
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Start } | Should -Throw '*Scope drift*'
        $fixture.Started | Should -BeFalse
    }
    It 'rejects nested groups instead of silently omitting their users' {
        $fixture.Nested = $true
        { & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure } | Should -Throw '*direct internal users*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }
    It 'removes only the dedicated source application, never target identities or partner policies' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Configure
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') @parameters -Phase Remove
        $fixture.SpPresent | Should -BeFalse
        $fixture.ApplicationPresent | Should -BeFalse
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 2 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -eq 'DELETE' -and $Uri -match '/(users|groups|policies)/' }
    }
}

AfterAll {
    Remove-Item Function:\Get-MgContext, Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}
