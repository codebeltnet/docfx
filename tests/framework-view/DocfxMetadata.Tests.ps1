BeforeAll {
    . "$PSScriptRoot/../../framework-views/FrameworkViewConventions.ps1"
    . "$PSScriptRoot/../../framework-views/DocfxMetadata.ps1"

    function Invoke-Step([string] $Log, [string] $Command, [string[]] $Arguments) {
        throw 'The unit test must provide a tool result.'
    }
}

Describe 'Staged DocFX metadata' {
    It 'reads MSBuild JSON even when the SDK prints a banner' {
        $output = 'SDK banner', '{', '  "Properties": {"TargetFramework": "net11.0"}', '}'
        (Read-MSBuildJson $output 'fixture.csproj').Properties.TargetFramework | Should -BeExactly 'net11.0'
        { Read-MSBuildJson @('unexpected output') 'fixture.csproj' } | Should -Throw '*fixture.csproj*unexpected output*'
    }

    It 'clears generated metadata and keeps authored documentation' {
        $folder = New-Item -ItemType Directory -Path "$TestDrive/stage"
        Clear-StagedMetadata "$folder/missing" "$folder/missing/.manifest"
        Set-Content -LiteralPath "$folder/toc.yml" -Value '- name: Authored'
        Set-Content -LiteralPath "$folder/overwrite.yml" -Value '### YamlMime:ManagedReferenceOverwrite'
        Set-Content -LiteralPath "$folder/Api.yml" -Value '### YamlMime:ManagedReference'
        Clear-StagedMetadata $folder.FullName "$folder/.manifest"
        Test-Path -LiteralPath "$folder/Api.yml" | Should -BeFalse
        Test-Path -LiteralPath "$folder/toc.yml" | Should -BeTrue
        Set-Content -LiteralPath "$folder/.manifest" -Value '{}'
        Set-Content -LiteralPath "$folder/toc.yml" -Value '- name: Generated'
        Clear-StagedMetadata $folder.FullName "$folder/.manifest"
        Test-Path -LiteralPath "$folder/.manifest" | Should -BeFalse
        Test-Path -LiteralPath "$folder/toc.yml" | Should -BeFalse
        Test-Path -LiteralPath "$folder/overwrite.yml" | Should -BeTrue
    }
}

Describe 'Cross-target DocFX reference recovery' {
    BeforeEach {
        $project = Join-Path $TestDrive 'project.csproj'
        $projects = @{ $project = @{ id = 0; properties = @('-p:Configuration=Release', '-p:AssemblyVersion=3.0.0.0') } }
        $group = @{ src = @(@{ src = $TestDrive; files = @('project.csproj') }); properties = @{ AssemblyVersion = '3.0.0.0' } }
        $hook = Join-Path $TestDrive 'recovery.targets'
        $authoredHook = Join-Path $TestDrive 'authored.targets'
        Set-Content -LiteralPath $authoredHook -Value '<Project />'
        $script:probe = @{
            Properties = @{ CustomAfterMicrosoftCommonTargets = ''; CustomBeforeMicrosoftCommonTargets = '' }
            Items = @{ _MSBuildProjectReferenceExistent = @(
                @{ ReferenceOutputAssembly = 'true'; NearestTargetFramework = 'netstandard2.0' }
            ) }
        }
        Mock Invoke-Step {
            if ($Arguments[0] -eq 'msbuild') {
                $script:probe | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Log
            }
        }
    }

    It 'builds only the affected view and preserves authored version properties' {
        Repair-CrossTargetReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeTrue
        $group.properties.CustomAfterMicrosoftCommonTargets | Should -BeExactly $hook
        $group.properties.AssemblyVersion | Should -BeExactly '3.0.0.0'
        Should -Invoke Invoke-Step -Exactly 1 -ParameterFilter {
            $Command -eq 'dotnet' -and ($Arguments -join ' ') -like 'build * -f net11.0 --no-restore -p:Configuration=Release -p:AssemblyVersion=3.0.0.0'
        }
    }

    It 'keeps same-target and build-only references on the ordinary path' {
        $script:probe.Items._MSBuildProjectReferenceExistent = @(
            @{ ReferenceOutputAssembly = 'true'; NearestTargetFramework = 'net11.0' }
            @{ ReferenceOutputAssembly = 'false'; NearestTargetFramework = 'netstandard2.0' }
        )
        Repair-CrossTargetReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeFalse
        $group.properties.Contains('CustomAfterMicrosoftCommonTargets') | Should -BeFalse
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }

    It 'uses the other hook when a consumer already uses the default recovery hook' {
        $script:probe.Properties.CustomAfterMicrosoftCommonTargets = $authoredHook
        Repair-CrossTargetReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeTrue
        $group.properties.Contains('CustomAfterMicrosoftCommonTargets') | Should -BeFalse
        $group.properties.CustomBeforeMicrosoftCommonTargets | Should -BeExactly $hook
    }

    It 'diagnoses an affected group with both MSBuild hooks in use' {
        $script:probe.Properties.CustomAfterMicrosoftCommonTargets = $authoredHook
        $script:probe.Properties.CustomBeforeMicrosoftCommonTargets = $authoredHook
        { Repair-CrossTargetReferences @($group) $projects 'net11.0' $TestDrive $hook } | Should -Throw '*needs an unused*'
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }
}
