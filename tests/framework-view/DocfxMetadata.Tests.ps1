BeforeAll {
    . "$PSScriptRoot/../../framework-views/FrameworkViewConventions.ps1"
    . "$PSScriptRoot/../../framework-views/DocfxMetadata.ps1"

    function Invoke-Step([string] $Log, [string] $Command, [string[]] $Arguments, [switch] $ReturnExitCode) {
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

Describe 'DocFX project reference recovery' {
    BeforeEach {
        $project = Join-Path $TestDrive 'project.csproj'
        $projects = @{ $project = @{ id = 0; properties = @('-p:Configuration=Release', '-p:AssemblyVersion=3.0.0.0') } }
        $group = @{ src = @(@{ src = $TestDrive; files = @('project.csproj') }); properties = @{ AssemblyVersion = '3.0.0.0' } }
        $hook = Join-Path $TestDrive 'recovery.targets'
        $authoredHook = Join-Path $TestDrive 'authored.targets'
        Set-Content -LiteralPath $authoredHook -Value '<Project />'
        $script:probe = @{
            Properties = @{ CustomAfterMicrosoftCommonTargets = ''; CustomBeforeMicrosoftCommonTargets = ''; ProduceReferenceAssembly = 'false' }
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
        Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeTrue
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
        Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeFalse
        $group.properties.Contains('CustomAfterMicrosoftCommonTargets') | Should -BeFalse
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }

    It 'uses reference assemblies for a diagnosed same-target dependency without compiling' {
        $dependency = Join-Path $TestDrive 'dependency.csproj'
        $script:probe.Items._MSBuildProjectReferenceExistent = @(
            @{ ReferenceOutputAssembly = 'true'; NearestTargetFramework = 'netstandard2.0'; FullPath = $dependency }
        )
        Repair-DocfxProjectReferences @($group) $projects 'netstandard2.0' $TestDrive $hook @($dependency) | Should -BeTrue
        $group.properties.ProduceReferenceAssembly | Should -BeExactly 'true'
        $group.properties.Contains('CustomAfterMicrosoftCommonTargets') | Should -BeFalse
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }

    It 'leaves unrelated, build-only and explicitly configured same-target references alone' {
        $dependency = Join-Path $TestDrive 'dependency.csproj'
        $script:probe.Items._MSBuildProjectReferenceExistent = @(
            @{ ReferenceOutputAssembly = 'true'; NearestTargetFramework = 'netstandard2.0'; FullPath = $dependency }
            @{ ReferenceOutputAssembly = 'false'; NearestTargetFramework = 'netstandard2.0'; FullPath = $project }
        )
        Repair-DocfxProjectReferences @($group) $projects 'netstandard2.0' $TestDrive $hook @($project) | Should -BeFalse
        $group.properties.ProduceReferenceAssembly = 'false'
        Repair-DocfxProjectReferences @($group) $projects 'netstandard2.0' $TestDrive $hook @($dependency) | Should -BeFalse
        $group.properties.ProduceReferenceAssembly | Should -BeExactly 'false'
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }

    It 'produces reference assemblies during a recovery build when both reference cases occur' {
        $dependency = Join-Path $TestDrive 'dependency.csproj'
        $script:probe.Items._MSBuildProjectReferenceExistent += @{
            ReferenceOutputAssembly = 'true'; NearestTargetFramework = 'net11.0'; FullPath = $dependency
        }
        Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook @($dependency) | Should -BeTrue
        $group.properties.ProduceReferenceAssembly | Should -BeExactly 'true'
        $group.properties.CustomAfterMicrosoftCommonTargets | Should -BeExactly $hook
        Should -Invoke Invoke-Step -Exactly 1 -ParameterFilter {
            $Arguments[0] -eq 'build' -and '-p:ProduceReferenceAssembly=true' -cin $Arguments
        }
    }

    It 'uses the other hook when a consumer already uses the default recovery hook' {
        $script:probe.Properties.CustomAfterMicrosoftCommonTargets = $authoredHook
        Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeTrue
        $group.properties.Contains('CustomAfterMicrosoftCommonTargets') | Should -BeFalse
        $group.properties.CustomBeforeMicrosoftCommonTargets | Should -BeExactly $hook
    }

    It 'preserves an explicitly configured hook even when its file does not exist' {
        $group.properties.CustomAfterMicrosoftCommonTargets = "$TestDrive/missing.targets"
        Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook | Should -BeTrue
        $group.properties.CustomAfterMicrosoftCommonTargets | Should -BeExactly "$TestDrive/missing.targets"
        $group.properties.CustomBeforeMicrosoftCommonTargets | Should -BeExactly $hook
    }

    It 'diagnoses an affected group with both MSBuild hooks in use' {
        $script:probe.Properties.CustomAfterMicrosoftCommonTargets = $authoredHook
        $script:probe.Properties.CustomBeforeMicrosoftCommonTargets = $authoredHook
        { Repair-DocfxProjectReferences @($group) $projects 'net11.0' $TestDrive $hook } | Should -Throw '*needs an unused*'
        Should -Invoke Invoke-Step -Exactly 0 -ParameterFilter { $Arguments[0] -eq 'build' }
    }
}

Describe 'DocFX metadata generation and cache publication' {
    BeforeEach {
        $root = New-Item -ItemType Directory -Path "$TestDrive/$([guid]::NewGuid())"
        $stage = (New-Item -ItemType Directory -Path "$root/net11").FullName
        $api = "$stage/api"
        $cache = "$root/net11.0.zip"
        $group = @{ dest = 'api'; properties = @{ TargetFramework = 'net11.0' } }
        Write-Json "$stage/framework-metadata.json" @{ metadata = @($group) }
        $script:missingReference = 'Found project reference without a matching metadata reference'

        Mock Repair-DocfxProjectReferences {
            $Metadata[0].properties.CustomAfterMicrosoftCommonTargets = $TargetsFile
            $true
        }
        Mock Invoke-Step {
            New-Item -ItemType Directory -Path "$stage/api" -Force | Out-Null
            if (Test-Path -LiteralPath "$stage/metadata-before-recovery.log") {
                Test-Path -LiteralPath "$stage/api/Partial.yml" | Should -BeFalse
                (Read-Json $Arguments[1]).metadata[0].properties.CustomAfterMicrosoftCommonTargets | Should -BeExactly 'recovery.targets'
                Set-Content -LiteralPath $Log 'warning: missing XML comments'
                Set-Content -LiteralPath "$stage/api/Complete.yml" '### YamlMime:ManagedReference'
                Write-Json "$stage/api/.manifest" @{ 'Fixture.Common' = 'Complete.yml' }
                return 0
            } else {
                Set-Content -LiteralPath $Log @("warning: ${script:missingReference}: $root/dependency.csproj", 'error: error CS1704')
                Set-Content -LiteralPath "$stage/api/Partial.yml" '### YamlMime:ManagedReference'
                Write-Json "$stage/api/.manifest" @{ 'Fixture.Common' = 'Partial.yml' }
                return -1
            }
        }
    }

    It 'verifies the retry log and caches only regenerated metadata' {
        New-DocfxMetadata @($group) @{} 'net11.0' 'net-11.0' $stage 'recovery.targets' 'docfx' $cache | Should -Be 1
        Should -Invoke Invoke-Step -Exactly 2 -ParameterFilter { $Command -eq 'docfx' -and $Arguments[0] -eq 'metadata' -and $ReturnExitCode }
        Should -Invoke Repair-DocfxProjectReferences -Exactly 1 -ParameterFilter { "$root/dependency.csproj" -cin $MissingProjects }
        Get-Content -LiteralPath "$stage/metadata-before-recovery.log" -Raw | Should -Match $script:missingReference
        $extracted = "$root/extracted"
        [IO.Compression.ZipFile]::ExtractToDirectory($cache, $extracted)
        (Get-Content -LiteralPath "$extracted/fingerprint") | Should -BeExactly (Get-MetadataFingerprint @("$extracted/api"))
        Test-Path -LiteralPath "$extracted/api/Complete.yml" | Should -BeTrue
        Test-Path -LiteralPath "$extracted/api/Partial.yml" | Should -BeFalse
    }

    It 'fails if the warning persists and leaves a previously published cache archive intact' {
        Mock Invoke-Step {
            New-Item -ItemType Directory -Path "$stage/api" -Force | Out-Null
            Write-Json "$stage/api/.manifest" @{ 'Fixture.Common' = 'Partial.yml' }
            Set-Content -LiteralPath $Log "warning: $script:missingReference"
            0
        }
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $cache)
        $hash = (Get-FileHash -LiteralPath $cache).Hash
        { New-DocfxMetadata @($group) @{} 'net11.0' 'net-11.0' $stage 'recovery.targets' 'docfx' $cache } |
            Should -Throw '*net-11.0*still has unresolved project references after recovery*metadata.log*metadata-before-recovery.log*'
        Should -Invoke Invoke-Step -Exactly 2
        (Get-FileHash -LiteralPath $cache).Hash | Should -BeExactly $hash
        Test-Path -LiteralPath "$root/generated-net11.0" | Should -BeFalse
    }

    It 'fails if the warning cannot be recovered and creates no archive' {
        Mock Repair-DocfxProjectReferences { $false }
        { New-DocfxMetadata @($group) @{} 'net11.0' 'net-11.0' $stage 'recovery.targets' 'docfx' $cache } |
            Should -Throw '*net-11.0*recovery was unavailable*metadata.log*'
        Should -Invoke Invoke-Step -Exactly 1
        Test-Path -LiteralPath $cache | Should -BeFalse
    }

    It 'accepts ordinary warnings without probing or compiling references' {
        Mock Invoke-Step {
            New-Item -ItemType Directory -Path "$stage/api" | Out-Null
            Write-Json "$stage/api/.manifest" @{ 'Fixture.Common' = 'Complete.yml' }
            Set-Content -LiteralPath $Log 'warning: missing XML comments'
            0
        }
        New-DocfxMetadata @($group) @{} 'net11.0' 'net-11.0' $stage 'recovery.targets' 'docfx' | Should -Be 1
        Should -Invoke Invoke-Step -Exactly 1
        Should -Invoke Repair-DocfxProjectReferences -Exactly 0
    }

    It 'rejects <reason> before publishing an archive' -ForEach @(
        @{ reason = 'a logged error'; exitCode = 0; message = 'error: failed generation'; manifest = $null; expected = '*metadata failed*metadata.log*' }
        @{ reason = 'a failed exit code'; exitCode = 1; message = ''; manifest = $null; expected = '*metadata failed*metadata.log*' }
        @{ reason = 'a missing manifest'; exitCode = 0; message = 'warning: missing XML comments'; manifest = $null; expected = '*Incomplete metadata*metadata.log*' }
        @{ reason = 'an empty manifest'; exitCode = 0; message = 'warning: missing XML comments'; manifest = @{}; expected = '*Empty DocFX metadata*net-11.0*' }
    ) {
        Mock Invoke-Step {
            if ($null -ne $manifest) {
                New-Item -ItemType Directory -Path "$stage/api" | Out-Null
                Write-Json "$stage/api/.manifest" $manifest
            }
            Set-Content -LiteralPath $Log $message
            $exitCode
        }
        { New-DocfxMetadata @($group) @{} 'net11.0' 'net-11.0' $stage 'recovery.targets' 'docfx' $cache } | Should -Throw $expected
        Should -Invoke Repair-DocfxProjectReferences -Exactly 0
        Test-Path -LiteralPath $cache | Should -BeFalse
    }
}
