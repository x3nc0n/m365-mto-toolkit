BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src\MtoToolkit.psm1')
    function global:Get-MgContext { throw 'Offline stub must be mocked.' }
    function global:Get-AzContext { throw 'Offline stub must be mocked.' }
    function global:Invoke-MgGraphRequest { param($Method,$Uri,$OutputType) throw 'Offline stub must be mocked.' }
    function global:Invoke-AzRestMethod { param($Method,$Path,$Payload) throw 'Offline stub must be mocked.' }
    function global:Get-AzRoleAssignment { param($ObjectId,$Scope,$RoleDefinitionId) throw 'Offline stub must be mocked.' }
}

Describe 'Target-group workspace authorization (offline mocks)' {
    BeforeEach {
        $config = Read-MtoConfiguration (Join-Path $script:root 'config\example.json')
        $targetId = $config.managedTenants[0].tenantId
        $config.managedTenants[0].authorization.targetGroupObjectId = '55555555-5555-4555-8555-555555555555'
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory $directory
        $configPath = Join-Path $directory 'configuration.json'
        $config | ConvertTo-Json -Depth 30 | Set-Content $configPath
        $parameters = @{ ConfigPath = $configPath; ManagedTenantId = $targetId; StateDirectory = $directory; Confirm = $false }
        $fixture = @{ Assignment = $null; Preexisting = $false; DeleteFails = $false }
        Mock Get-MgContext { @{ TenantId = '22222222-2222-4222-8222-222222222222'; AuthType = 'Delegated' } } -ModuleName MtoToolkit
        Mock Get-AzContext { @{ Tenant = @{ Id = '22222222-2222-4222-8222-222222222222' }; Subscription = @{ Id = '33333333-3333-4333-8333-333333333333' } } } -ModuleName MtoToolkit
        Mock Invoke-MgGraphRequest {
            @{ id = '55555555-5555-4555-8555-555555555555'; securityEnabled = $true; mailEnabled = $false; groupTypes = @(); isAssignableToRole = $false }
        } -ModuleName MtoToolkit
        Mock Get-AzRoleAssignment {
            if ($fixture.Preexisting) {
                @{ Scope = '/subscriptions/33333333-3333-4333-8333-333333333333/resourceGroups/rg-fabrikam-security/providers/Microsoft.OperationalInsights/workspaces/law-fabrikam-security' }
            }
        }
        Mock Invoke-AzRestMethod {
            param($Method,$Path,$Payload)
            if ($Path -notlike '*roleAssignments*') {
                return @{ StatusCode = 200; Content = '{"id":"existing-workspace"}' }
            }
            switch ($Method) {
                'GET' {
                    if ($fixture.Assignment) { return @{ StatusCode = 200; Content = ($fixture.Assignment | ConvertTo-Json -Depth 10) } }
                    return @{ StatusCode = 404; Content = '{}' }
                }
                'PUT' {
                    $fixture.Assignment = $Payload | ConvertFrom-Json -AsHashtable
                    return @{ StatusCode = 201; Content = $Payload }
                }
                'DELETE' {
                    if ($fixture.DeleteFails) { return @{ StatusCode = 403; Content = '{}' } }
                    $fixture.Assignment = $null
                    return @{ StatusCode = 204; Content = '' }
                }
                default { throw 'Unexpected offline request.' }
            }
        }
    }
    It 'Apply WhatIf never writes cloud resources or ownership state' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply -WhatIf
        Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -ne 'GET' }
        @(Get-ChildItem $directory -Filter 'access-*').Count | Should -Be 0
    }
    It 'creates one scoped role assignment and repeats idempotently' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $fixture.Assignment.properties.principalId | Should -Be '55555555-5555-4555-8555-555555555555'
        $fixture.Assignment.properties.roleDefinitionId | Should -BeLike '*/8d289c81-5878-46d4-8554-54e1e3d8b5cb'
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName MtoToolkit -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }
    It 'preserves preexisting assignments without claiming ownership' {
        $fixture.Preexisting = $true
        $result = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $result.Status | Should -Be 'PreexistingPreserved'
        Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'PUT' }
        { & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Remove } | Should -Throw '*No verified toolkit-created*'
    }
    It 'removes only its recorded assignment and then clears ownership state' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Remove
        $fixture.Assignment | Should -BeNullOrEmpty
        @(Get-ChildItem $directory -Filter 'access-*.json').Count | Should -Be 0
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' -and $Path -like '*roleAssignments*' }
    }
    It 'retains ownership state if removal is denied' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $fixture.DeleteFails = $true
        { & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Remove } | Should -Throw '*403*'
        @(Get-ChildItem $directory -Filter 'access-*.json').Count | Should -Be 1
    }
    It 'refuses a changed remote assignment principal before deletion' {
        $null = & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Apply
        $fixture.Assignment.properties.principalId = 'somebody-else'
        { & (Join-Path $script:root 'scripts\Invoke-MtoTargetAccess.ps1') @parameters -Mode Remove } | Should -Throw '*ownership check failed*'
        Should -Invoke Invoke-AzRestMethod -Times 0 -ParameterFilter { $Method -eq 'DELETE' }
    }
}

AfterAll {
    Remove-Item Function:\Get-MgContext,Function:\Get-AzContext,Function:\Invoke-MgGraphRequest,Function:\Invoke-AzRestMethod,Function:\Get-AzRoleAssignment -ErrorAction SilentlyContinue
}
