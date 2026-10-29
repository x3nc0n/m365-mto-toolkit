BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\src\MtoToolkit.psm1') -Force
}
BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src\MtoToolkit.psm1')
    # SDK stubs make these tests independent of installed cloud modules and credentials.
    function global:Get-MgContext { throw 'Offline stub must be mocked.' }
    function global:Get-AzContext { throw 'Offline stub must be mocked.' }
    function global:Invoke-MgGraphRequest {
        param($Method, $Uri, $OutputType, $Body, $ContentType)
        throw 'Offline stub must be mocked.'
    }
}

Describe 'Configuration boundary' {
    It 'accepts the fictional example with all approval gates closed' {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $config.managedTenants.Count | Should -Be 1
        $config.managedTenants[0].synchronization.mode | Should -Be 'Groups'
        $config.managedTenants[0].synchronization.approveStart | Should -BeFalse
        $config.managedTenants[0].authorization.profile | Should -Be 'Reader'
    }
    It 'rejects source equal to target' {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $config.managedTenants[0].tenantId = $config.managingTenant.tenantId
        $path = Join-Path $TestDrive 'equal.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content $path
        { Read-MtoConfiguration $path } | Should -Throw '*must differ*'
    }
    It 'rejects ambiguous existing/create group selection' {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $config.managedTenants[0].sourceGroup.objectId = '44444444-4444-4444-8444-444444444444'
        $path = Join-Path $TestDrive 'group.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content $path
        { Read-MtoConfiguration $path } | Should -Throw '*Choose create*'
    }
    It 'rejects invalid IDs, unknown properties and unsupported modes' -ForEach @(
        @{ Field = 'tenantId'; Value = 'not-a-guid' },
        @{ Field = 'unexpected'; Value = 'reject-me' }
    ) {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $config.managedTenants[0][$Field] = $Value
        $path = Join-Path $TestDrive 'invalid.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content $path
        { Read-MtoConfiguration $path } | Should -Throw
    }
}

Describe 'Context and Graph transport' {
    InModuleScope MtoToolkit {
        It 'rejects another tenant and app-only authentication' {
            Mock Get-MgContext { @{ TenantId = 'wrong'; AuthType = 'Delegated' } }
            { Assert-MtoGraphContext -TenantId 'expected' } | Should -Throw
            Mock Get-MgContext { @{ TenantId = 'expected'; AuthType = 'AppOnly' } }
            { Assert-MtoGraphContext -TenantId 'expected' } | Should -Throw
        }
        It 'rejects a matching Azure subscription in a different tenant' {
            Mock Get-AzContext { @{ Tenant = @{ Id = 'wrong' }; Subscription = @{ Id = 'subscription' } } }
            { Assert-MtoAzContext -TenantId 'expected' -SubscriptionId 'subscription' } | Should -Throw
        }
        It 'follows all Graph pages' {
            Mock Invoke-MgGraphRequest {
                if ($Uri -like '*second*') { return @{ value = @(@{ id = 'two' }) } }
                return @{ value = @(@{ id = 'one' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups?second' }
            }
            $items = @(Get-MtoGraphCollection 'groups')
            $items.Count | Should -Be 2
            $items[1].id | Should -Be 'two'
            Should -Invoke Invoke-MgGraphRequest -Times 2 -Exactly
        }
        It 'rejects pagination to another host without making the second request' {
            Mock Invoke-MgGraphRequest { @{ value = @(); '@odata.nextLink' = 'https://untrusted.example/page' } }
            { Get-MtoGraphCollection 'groups' } | Should -Throw '*Only Microsoft Graph*'
            Should -Invoke Invoke-MgGraphRequest -Times 1 -Exactly
        }
        It 'rejects a pagination loop' {
            Mock Invoke-MgGraphRequest { @{ value = @(); '@odata.nextLink' = 'groups' } }
            { Get-MtoGraphCollection 'groups' } | Should -Throw '*loop*'
        }
        It 'does not convert authorization failures into absence' {
            Mock Invoke-MgGraphRequest { throw [System.UnauthorizedAccessException]::new('HTTP 403') }
            { Get-MtoOptionalGraph 'groups/test' } | Should -Throw '*403*'
        }
        It 'accepts only typed HTTP 404 as absent' {
            Mock Invoke-MgGraphRequest {
                $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
                $exception = [System.Exception]::new('HTTP 404')
                $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
                throw $exception
            }
            Get-MtoOptionalGraph 'groups/test' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Group provisioning schema safety' {
    BeforeEach {
        $schema = @{
            '@odata.context' = 'metadata'
            synchronizationRules = @(@{
                objectMappings = @(
                    @{
                        sourceObjectName = 'User'; targetObjectName = 'User'; enabled = $true
                        attributeMappings = @(
                            @{ targetAttributeName = 'userType'; flowType = 'Always'; source = @{ type = 'Constant'; name = 'Member' } }
                            @{ targetAttributeName = 'displayName'; source = @{ type = 'Attribute'; name = 'displayName' } }
                        )
                    },
                    @{
                        sourceObjectName = 'Group'; targetObjectName = 'Group'; enabled = $false
                        attributeMappings = @(@{ targetAttributeName = 'members'; source = @{ type = 'Attribute'; name = 'members' } })
                    }
                )
            })
        }
    }
    It 'enables groups/memberships, creates Guest users only, preserves unrelated mappings' {
        $result = ConvertTo-MtoGroupSyncSchema -Schema $schema
        $objects = $result.synchronizationRules[0].objectMappings
        $objects[0].attributeMappings[0].source.name | Should -Be 'Guest'
        $objects[0].attributeMappings[0].flowType | Should -Be 'ObjectAddOnly'
        $objects[0].attributeMappings[1].source.name | Should -Be 'displayName'
        $objects[1].enabled | Should -BeTrue
        $objects[1].attributeMappings[0].targetAttributeName | Should -Be 'members'
        $result.ContainsKey('@odata.context') | Should -BeFalse
    }
    It 'fails closed if the Microsoft template has no group mapping' {
        $schema.synchronizationRules[0].objectMappings = @($schema.synchronizationRules[0].objectMappings[0])
        { ConvertTo-MtoGroupSyncSchema $schema } | Should -Throw '*one User and one Group*'
    }
    It 'fails closed if membership mapping is absent' {
        $schema.synchronizationRules[0].objectMappings[1].attributeMappings = @()
        { ConvertTo-MtoGroupSyncSchema $schema } | Should -Throw '*members mappings*'
    }
}

Describe 'Local ownership state' {
    It 'persists resource IDs and refuses state from another relationship' {
        $path = Join-Path $TestDrive 'state\sync.json'
        $state = Read-MtoState $path 'source' 'target'
        $state.groupId = 'created-group'
        Save-MtoState $state $path
        (Read-MtoState $path 'source' 'target').groupId | Should -Be 'created-group'
        { Read-MtoState $path 'other' 'target' } | Should -Throw '*mismatch*'
    }
    It 'prevents concurrent mutation of the same state' {
        $path = Join-Path $TestDrive 'lock\state.json'
        $lock = Enter-MtoStateLock $path
        try { { Enter-MtoStateLock $path } | Should -Throw '*locked*' }
        finally { $lock.Dispose() }
    }
}

Describe 'Local planning does not authenticate or mutate' {
    BeforeEach {
        Mock Get-MgContext { throw 'Must not authenticate for local plan.' } -ModuleName MtoToolkit
        Mock Invoke-MgGraphRequest { throw 'Must not call Graph for local plan.' } -ModuleName MtoToolkit
        Mock Get-AzContext { throw 'Must not call Azure for local plan.' } -ModuleName MtoToolkit
    }
    It 'plans group provisioning without cloud modules or credentials' {
        $result = & (Join-Path $script:root 'scripts\Invoke-MtoSync.ps1') -ConfigPath (Join-Path $script:root 'config\example.json') -ManagedTenantId '22222222-2222-4222-8222-222222222222' -Phase Configure
        $result.Evidence | Should -Be 'LocalPlan'
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
    It 'plans workspace RBAC independently of Defender RBAC' {
        $result = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') -ConfigPath (Join-Path $script:root 'config\example.json') -ManagedTenantId '22222222-2222-4222-8222-222222222222'
        $result.SentinelRole | Should -Be 'Reader'
        $result.TargetGroupId | Should -BeNullOrEmpty
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0
    }
    It 'uses the documented built-in Sentinel role IDs' {
        Get-MtoSentinelRole Reader | Should -Be '8d289c81-5878-46d4-8554-54e1e3d8b5cb'
        Get-MtoSentinelRole Responder | Should -Be '3e150937-b8fe-4cfb-8069-0eaf05ecd056'
        Get-MtoSentinelRole Contributor | Should -Be 'ab8e14d6-4a74-4a29-9ba8-549422addade'
    }
}

AfterAll {
    Remove-Item Function:\Get-MgContext, Function:\Get-AzContext, Function:\Invoke-MgGraphRequest -ErrorAction SilentlyContinue
}
