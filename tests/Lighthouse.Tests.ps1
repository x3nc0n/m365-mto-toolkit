BeforeAll {
    $script:repository = Split-Path $PSScriptRoot -Parent
    $script:fixtureRoot = Join-Path $script:repository ".local\lighthouse-tests-$([guid]::NewGuid().ToString('N'))"
    foreach ($directory in @('scripts', 'templates', 'src')) {
        New-Item -ItemType Directory -Path (Join-Path $script:fixtureRoot $directory) -Force | Out-Null
    }
    Copy-Item (Join-Path $script:repository 'scripts\Invoke-MtoLighthouse.ps1') (Join-Path $script:fixtureRoot 'scripts')
    Copy-Item (Join-Path $script:repository 'templates\lighthouse-rg.json') (Join-Path $script:fixtureRoot 'templates')
    # Isolate Lighthouse behavior from shared configuration validation and real Az modules.
    @'
function Read-MtoConfiguration {
    param([string] $Path)
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}
Export-ModuleMember -Function Read-MtoConfiguration
'@ | Set-Content (Join-Path $script:fixtureRoot 'src\MtoToolkit.psm1')
    $script:entryPoint = Join-Path $script:fixtureRoot 'scripts\Invoke-MtoLighthouse.ps1'
    function Get-AzContext { [CmdletBinding()] param() throw 'Unmocked Az call' }
    function Invoke-AzRestMethod {
        [CmdletBinding()]
        param($Path, $Method, $DefaultProfile)
        throw 'Unmocked Az call'
    }
    function New-AzSubscriptionDeployment {
        [CmdletBinding(SupportsShouldProcess)]
        param($Name, $Location, $TemplateFile, $TemplateParameterObject, $DefaultProfile)
        throw 'Unmocked Az call'
    }
}

AfterAll {
    Remove-Module MtoToolkit -ErrorAction SilentlyContinue
    Remove-Variable -Name MtoLighthouseOfflineFixture -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:fixtureRoot -Recurse -Force
}

Describe 'Offline Lighthouse planning and ownership lifecycle' {
    BeforeEach {
        $script:customer = '22222222-2222-2222-2222-222222222222'
        $script:manager = '11111111-1111-1111-1111-111111111111'
        $script:subscription = '33333333-3333-3333-3333-333333333333'
        $script:readerRole = '8d289c81-5878-46d4-8554-54e1e3d8b5cb'
        $script:configuration = @{
            managingTenant = @{ tenantId = $script:manager }
            managedTenants = @(@{
                tenantId = $script:customer
                azure = @{ subscriptionId = $script:subscription; resourceGroup = 'existing-sentinel'; workspaceName = 'existing-workspace' }
                lighthouse = @{ authorizations = @(@{ principalId = '44444444-4444-4444-4444-444444444444' }) }
            })
        }
        $script:configPath = Join-Path $script:fixtureRoot 'config.json'
        $script:configuration | ConvertTo-Json -Depth 20 | Set-Content $script:configPath
        Remove-Item (Join-Path $script:fixtureRoot '.local') -Recurse -Force -ErrorAction SilentlyContinue
        $script:remote = @{}
        $script:deleted = [Collections.Generic.List[string]]::new()
        $script:context = [pscustomobject] @{
            Tenant = @{ Id = $script:customer }; Subscription = @{ Id = $script:subscription }
        }
        $global:MtoLighthouseOfflineFixture = @{
            Context = $script:context; Remote = $script:remote
            Deleted = $script:deleted; Subscription = $script:subscription
            Root = $script:fixtureRoot; StateObservedBeforeDeployment = $false
        }
        Mock Get-AzContext { $global:MtoLighthouseOfflineFixture.Context }
        Mock Invoke-AzRestMethod {
            $fixture = $global:MtoLighthouseOfflineFixture
            $id = ($Path -split '\?')[0]
            if ($Method -eq 'DELETE') {
                $fixture.Deleted.Add($id)
                $fixture.Remote.Remove($id)
                return @{ StatusCode = 204; Content = '' }
            }
            if ($fixture.Remote.ContainsKey($id)) {
                return @{ StatusCode = 200; Content = ($fixture.Remote[$id] | ConvertTo-Json -Depth 20) }
            }
            @{ StatusCode = 404; Content = '' }
        }
        Mock New-AzSubscriptionDeployment {
            $fixture = $global:MtoLighthouseOfflineFixture
            $parameters = $TemplateParameterObject
            $fixture.StateObservedBeforeDeployment = Test-Path (Join-Path $fixture.Root ".local\lighthouse\$($parameters.registrationAssignmentName).json")
            if (-not $fixture.StateObservedBeforeDeployment) { throw 'Ownership must be persisted before deployment.' }
            $definitionId = "/subscriptions/$($fixture.Subscription)/providers/Microsoft.ManagedServices/registrationDefinitions/$($parameters.registrationDefinitionName)"
            $assignmentId = "/subscriptions/$($fixture.Subscription)/resourceGroups/existing-sentinel/providers/Microsoft.ManagedServices/registrationAssignments/$($parameters.registrationAssignmentName)"
            $fixture.Remote[$definitionId] = @{
                id = $definitionId
                properties = @{
                    managedByTenantId = $parameters.managedByTenantId
                    description = $parameters.ownershipMarker
                    registrationDefinitionName = "m365-mto-toolkit-$($parameters.registrationDefinitionName)"
                    authorizations = $parameters.authorizations
                    provisioningState = 'Succeeded'
                }
            }
            $fixture.Remote[$assignmentId] = @{
                id = $assignmentId
                properties = @{ registrationDefinitionId = $definitionId; provisioningState = 'Succeeded' }
            }
        }
    }

    It 'plans deterministically offline and defaults to Sentinel Reader' {
        $first = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
        $second = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
        $first.AssignmentId | Should -Be $second.AssignmentId
        $first.DefinitionId | Should -Match "^/subscriptions/$script:subscription/providers/"
        $first.AssignmentId | Should -Match '/resourceGroups/existing-sentinel/providers/'
        $first.Authorizations[0].roleDefinitionId | Should -Be $script:readerRole
        Test-Path $first.StatePath | Should -BeFalse
        Should -Invoke Get-AzContext -Times 0
        Should -Invoke Invoke-AzRestMethod -Times 0
    }

    It 'makes Apply WhatIf entirely offline without state writes' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -WhatIf
        Test-Path $plan.StatePath | Should -BeFalse
        Test-Path (Join-Path $script:fixtureRoot '.local') | Should -BeFalse
        Should -Invoke Get-AzContext -Times 0
        Should -Invoke New-AzSubscriptionDeployment -Times 0
    }

    It 'rejects broad Owner role authorization' {
        $script:configuration.managedTenants[0].lighthouse.authorizations[0].roleDefinitionId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        $script:configuration | ConvertTo-Json -Depth 20 | Set-Content $script:configPath
        { & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer } |
            Should -Throw '*Only Microsoft Sentinel*'
    }

    It 'accepts explicit Sentinel Responder and Contributor without adding Reader' {
        foreach ($role in @('3e150937-b8fe-4cfb-8069-0eaf05ecd056', 'ab8e14d6-4a74-4a29-9ba8-549422addade')) {
            $script:configuration.managedTenants[0].lighthouse.authorizations[0].roleDefinitionId = $role
            $script:configuration | ConvertTo-Json -Depth 20 | Set-Content $script:configPath
            $plan = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
            $plan.Authorizations.Count | Should -Be 1
            $plan.Authorizations[0].roleDefinitionId | Should -Be $role
        }
    }

    It 'rejects a wrong tenant before any remote access' {
        $script:context.Tenant.Id = $script:manager
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*tenant AND subscription*'
        Should -Invoke Invoke-AzRestMethod -Times 0
        Should -Invoke New-AzSubscriptionDeployment -Times 0
    }

    It 'rejects a wrong subscription before any remote access' {
        $script:context.Subscription.Id = $script:manager
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*tenant AND subscription*'
        Should -Invoke Invoke-AzRestMethod -Times 0
    }

    It 'does not adopt an existing definition when state is missing' {
        $plan = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
        $script:remote[$plan.DefinitionId] = @{ id = $plan.DefinitionId; properties = @{} }
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*without ownership state*'
        Test-Path $plan.StatePath | Should -BeFalse
        Should -Invoke New-AzSubscriptionDeployment -Times 0
    }

    It 'refuses a concurrent operation holding the exact state lock before any remote access' {
        $plan = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
        New-Item -ItemType Directory -Path (Split-Path $plan.StatePath -Parent) -Force | Out-Null
        $heldLock = [IO.File]::Open("$($plan.StatePath).lock", [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
                Should -Throw
            Should -Invoke Get-AzContext -Times 0
            Should -Invoke Invoke-AzRestMethod -Times 0
            Test-Path $plan.StatePath | Should -BeFalse
        } finally { $heldLock.Dispose() }
    }

    It 'persists ownership before deploying and makes repeat Apply idempotent' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        Test-Path $plan.StatePath | Should -BeTrue
        $state = Get-Content $plan.StatePath -Raw | ConvertFrom-Json
        $state.ownershipMarker | Should -Match '^m365-mto-toolkit/lighthouse:'
        $global:MtoLighthouseOfflineFixture.StateObservedBeforeDeployment | Should -BeTrue
        & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false | Out-Null
        Should -Invoke New-AzSubscriptionDeployment -Times 1
    }

    It 'refuses a remote definition with a changed ownership marker' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote[$plan.DefinitionId].properties.description = 'someone else'
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*ownership*'
        $script:deleted.Count | Should -Be 0
        Test-Path $plan.StatePath | Should -BeTrue
    }

    It 'refuses tampered local IDs before any further remote access' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $state = Get-Content $plan.StatePath -Raw | ConvertFrom-Json -AsHashtable
        $state.definitionId = '/subscriptions/unrelated/definition'
        $state | ConvertTo-Json -Depth 20 | Set-Content $plan.StatePath
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*Local Lighthouse state does not match*'
        $script:deleted.Count | Should -Be 0
    }

    It 'refuses changed remote home-tenant identity' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote[$plan.DefinitionId].properties.managedByTenantId = $script:customer
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*identity/ownership/authorizations mismatch*'
        $script:deleted.Count | Should -Be 0
    }

    It 'refuses changed remote authorizations before any delete' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote[$plan.DefinitionId].properties.authorizations[0].roleDefinitionId = 'ab8e14d6-4a74-4a29-9ba8-549422addade'
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*identity/ownership/authorizations mismatch*'
        $script:deleted.Count | Should -Be 0
        Test-Path $plan.StatePath | Should -BeTrue
    }

    It 'rejects changed configuration roles rather than updating an owned definition' {
        & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false | Out-Null
        $script:configuration.managedTenants[0].lighthouse.authorizations[0].roleDefinitionId = 'ab8e14d6-4a74-4a29-9ba8-549422addade'
        $script:configuration | ConvertTo-Json -Depth 20 | Set-Content $script:configPath
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*Local Lighthouse state does not match*'
        Should -Invoke New-AzSubscriptionDeployment -Times 1
    }

    It 'recovers an owned definition whose assignment was not created' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote.Remove($plan.AssignmentId)
        & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false | Out-Null
        $script:remote.ContainsKey($plan.AssignmentId) | Should -BeTrue
        Should -Invoke New-AzSubscriptionDeployment -Times 2
    }

    It 'refuses an assignment referencing a different definition' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote[$plan.AssignmentId].properties.registrationDefinitionId = '/subscriptions/other/definition'
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*assignment identity/reference mismatch*'
        $script:deleted.Count | Should -Be 0
    }

    It 'removes only the exact assignment then definition and clears confirmed state' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        $script:remote['/unrelated'] = @{ id = '/unrelated' }
        & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false | Out-Null
        $script:deleted.Count | Should -Be 2
        $script:deleted[0] | Should -Be $plan.AssignmentId
        $script:deleted[1] | Should -Be $plan.DefinitionId
        $script:remote.ContainsKey('/unrelated') | Should -BeTrue
        Test-Path $plan.StatePath | Should -BeFalse
    }

    It 'does not delete resources or state for Remove WhatIf' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -WhatIf | Out-Null
        $script:deleted.Count | Should -Be 0
        Test-Path $plan.StatePath | Should -BeTrue
        Should -Invoke Get-AzContext -Times 2
    }

    It 'refuses Remove without ownership state' {
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*No toolkit ownership state*'
        Should -Invoke Invoke-AzRestMethod -Times 0
    }

    It 'retains ownership state after a failed deployment for recovery' {
        Mock New-AzSubscriptionDeployment { throw 'simulated deployment failure' }
        $plan = & $script:entryPoint -Mode Plan -ConfigPath $script:configPath -ManagedTenantId $script:customer
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*simulated deployment failure*'
        Test-Path $plan.StatePath | Should -BeTrue
    }

    It 'retains ownership state and does not delete the definition after a failed assignment delete' {
        $plan = & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false
        Mock Invoke-AzRestMethod { @{ StatusCode = 403; Content = '' } } -ParameterFilter { $Method -eq 'DELETE' }
        { & $script:entryPoint -Mode Remove -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*Deletion failed*'
        Test-Path $plan.StatePath | Should -BeTrue
        $script:remote.ContainsKey($plan.DefinitionId) | Should -BeTrue
        Should -Invoke Invoke-AzRestMethod -Times 1 -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'fails closed on HTTP errors instead of treating them as missing resources' {
        Mock Invoke-AzRestMethod { @{ StatusCode = 403; Content = '' } }
        { & $script:entryPoint -Mode Apply -ConfigPath $script:configPath -ManagedTenantId $script:customer -Confirm:$false } |
            Should -Throw '*HTTP 403*'
        Should -Invoke New-AzSubscriptionDeployment -Times 0
    }
}

Describe 'Lighthouse ARM topology' {
    It 'creates no paid resources and keeps the definition at subscription scope' {
        $template = Get-Content (Join-Path $script:repository 'templates\lighthouse-rg.json') -Raw | ConvertFrom-Json
        $template.'$schema' | Should -Match 'subscriptionDeploymentTemplate'
        $template.resources.Count | Should -Be 2
        $template.resources[0].type | Should -Be 'Microsoft.ManagedServices/registrationDefinitions'
        $template.resources[1].type | Should -Be 'Microsoft.Resources/deployments'
        $template.resources[1].resourceGroup | Should -Be "[parameters('resourceGroupName')]"
        $template.resources[1].properties.mode | Should -Be 'Incremental'
        $nested = $template.resources[1].properties.template.resources
        $nested.Count | Should -Be 1
        $nested[0].type | Should -Be 'Microsoft.ManagedServices/registrationAssignments'
    }
}
