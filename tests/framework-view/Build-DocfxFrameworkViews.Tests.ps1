BeforeAll {
    $build = "$PSScriptRoot/../../framework-views/Build-DocfxFrameworkViews.ps1"
}

Describe 'Framework view build preflight' {
    BeforeEach {
        $docs = (New-Item -ItemType Directory -Path "$TestDrive/docs" -Force).FullName
        $output = "$TestDrive/output"
        $config = "$docs/docfx.json"
        '{"metadata":[{"dest":"api"}],"build":{}}' | Set-Content -LiteralPath $config
    }

    It 'rejects output that overlaps the authored inputs' {
        { & $build -DocfxConfig $config -OutputRoot "$docs/generated" } | Should -Throw '*dedicated directory outside the DocFX input directory*'
        { & $build -DocfxConfig $config -OutputRoot $TestDrive } | Should -Throw '*dedicated directory outside the DocFX input directory*'
    }

    It 'requires an explicit input fingerprint when using a metadata cache' {
        { & $build -DocfxConfig $config -OutputRoot $output -MetadataCache "$TestDrive/cache" } |
            Should -Throw '*metadata cache requires a metadata input fingerprint*'
    }

    It 'rejects a cache that overlaps either the authored inputs or the output' {
        foreach ($cache in "$docs/cache", "$output/cache", $TestDrive) {
            { & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture' } |
                Should -Throw '*dedicated metadata cache directory*'
        }
    }

    It 'rejects an unsafe rendering destination before creating output or cache directories' {
        '{"metadata":[{"dest":"api"}],"build":{"dest":"../escape"}}' | Set-Content -LiteralPath $config
        $cache = "$TestDrive/cache"
        { & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture' } |
            Should -Throw '*relative DocFX site destination*'
        Test-Path -LiteralPath $output | Should -BeFalse
        Test-Path -LiteralPath $cache | Should -BeFalse
    }
}

Describe 'Framework view build with stubbed tools' {
    BeforeAll {
        function dotnet {
            $global:LASTEXITCODE = 0
            Add-Content -LiteralPath "$fixture/dotnet.log" -Value ($args -join ' ')
            switch ($args[0]) {
                '--version' {
                    if ($scenario -eq 'project SDK failure' -and (Get-Location).Path -eq $docs) { $global:LASTEXITCODE = 1 }
                    '11.0.100'
                }
                'run' {
                    if ($scenario -eq 'resolver failure') {
                        $global:LASTEXITCODE = 1
                        'fixture resolver failure'
                    } else {
                        $mapping = @{ files = @("$fixture/Library.csproj") }
                        if ($scenario -ne 'single framework') { $mapping.source = $fixture }
                        switch ($scenario) {
                            'assembly input' { $mapping.files = @("$fixture/Library.dll") }
                            'project inside output' { $mapping.files = @("$output/Library.csproj") }
                            'empty mapping' { $mapping.files = @() }
                        }
                        $mappings = @(, @($mapping))
                        if ($scenario -eq 'conflicting properties') { $mappings += , @($mapping) }
                        ConvertTo-Json -InputObject $mappings -Depth 4 | Set-Content -LiteralPath $args[-1]
                    }
                }
                'msbuild' {
                    if ($args -contains '-t:PrepareProjectReferences') {
                        (@{
                            Properties = @{ ProduceReferenceAssembly = 'true' }
                            Items = @{ _MSBuildProjectReferenceExistent = @() }
                        } | ConvertTo-Json -Depth 4) -split '\r?\n'
                    } else {
                        $properties = @{ TargetFrameworks = 'net10.0;net11.0'; TargetFramework = '' }
                        switch ($scenario) {
                            'MSBuild evaluation failure' { $global:LASTEXITCODE = 1 }
                            'no frameworks' { $properties.TargetFrameworks = '' }
                            'single framework' { $properties.TargetFramework = 'net11.0' }
                        }
                        (@{ Properties = $properties } | ConvertTo-Json) -split '\r?\n'
                    }
                }
            }
        }
    }

    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $fixture = (New-Item -ItemType Directory -Path "$TestDrive/$([guid]::NewGuid())").FullName
        $docs = (New-Item -ItemType Directory -Path "$fixture/docs").FullName
        $config = "$docs/docfx.json"
        $output = "$fixture/output"
        $cache = "$fixture/cache"
        $cli = "$fixture/docfx.ps1"
        $store = (New-Item -ItemType Directory -Path "$fixture/.store/docfx/2.81.0/docfx/2.81.0/tools/net10.0/any").FullName
        New-Item -ItemType File -Path "$store/Docfx.Glob.dll", "$fixture/Library.csproj" | Out-Null
        $settings = @{ metadata = @(@{ dest = 'api' }); build = @{ template = @('default', 'modern', 'templates/ms-style') } }
        ConvertTo-Json $settings -Depth 5 | Set-Content -LiteralPath $config
        @'
$global:LASTEXITCODE = 0
Add-Content -LiteralPath "$PSScriptRoot/docfx.log" -Value ($args -join ' ')
switch ($args[0]) {
    '--version' {
        switch ($scenario) {
            'CLI version failure' { $global:LASTEXITCODE = 1 }
            'wrong CLI version' { '2.80.0' }
            default { '2.81.0' }
        }
    }
    'metadata' {
        $stage = Split-Path -Parent $args[1]
        New-Item -ItemType Directory -Path "$stage/api" | Out-Null
        '{"Fixture.Library":"Library.yml"}' | Set-Content -LiteralPath "$stage/api/.manifest"
        '### YamlMime:ManagedReference' | Set-Content -LiteralPath "$stage/api/Library.yml"
        if (Test-Path -LiteralPath "$PSScriptRoot/unresolved") {
            "warning: [Warning] Found project reference without a matching metadata reference: $PSScriptRoot/unresolved.csproj"
        } else {
            'warning: missing XML comments'
        }
    }
    'build' {
        $stage = Split-Path -Parent $args[1]
        $site = Join-Path $stage ((Get-Content -LiteralPath $args[1] -Raw | ConvertFrom-Json).build.dest)
        New-Item -ItemType Directory -Path "$site/api" | Out-Null
        New-Item -ItemType Directory -Path "$site/public" | Out-Null
        'Fixture.Library' | Set-Content -LiteralPath "$site/api/Library.html"
        'references: []' | Set-Content -LiteralPath "$site/xrefmap.yml"
        '{}' | Set-Content -LiteralPath "$site/index.json"
        $asset = if ($scenario -eq 'different shared assets') { Split-Path -Leaf $stage } else { 'shared' }
        $asset | Set-Content -LiteralPath "$site/public/shared.js"
    }
}
'@ | Set-Content -LiteralPath $cli
        Mock Get-Command {
            if ($scenario -ne 'missing CLI') { [pscustomobject]@{ Source = $cli } }
        } -ParameterFilter { $Name -eq 'docfx' }
    }

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
    }

    It 'continues through rendering on ordinary warnings and skips metadata on a warm cache' {
        & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture'
        Test-Path -LiteralPath "$output/site/api/Library.html" | Should -BeTrue
        (Get-Content -LiteralPath "$output/site/framework-views.json" -Raw | ConvertFrom-Json).defaultView | Should -BeExactly 'net-11.0'
        @(Get-ChildItem -LiteralPath $cache -Filter '*.zip' -Recurse).Count | Should -Be 2
        & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture'
        @(Select-String -LiteralPath "$fixture/docfx.log" -Pattern '^metadata .* --noRestore$').Count | Should -Be 2
        @(Select-String -LiteralPath "$fixture/docfx.log" -Pattern '^build ').Count | Should -Be 4
        @(Select-String -LiteralPath "$fixture/dotnet.log" -Pattern '^restore ').Count | Should -Be 1
        Get-Content -LiteralPath "$fixture/dotnet.log" -Raw | Should -Not -Match '(?m)^build |PrepareProjectReferences'

        Set-Content -LiteralPath (Get-ChildItem -LiteralPath $cache -Filter 'net11.0.zip' -Recurse).FullName 'invalid archive'
        & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture'
        Test-Path -LiteralPath "$output/net11/metadata.log" | Should -BeTrue
        Test-Path -LiteralPath "$output/net10/metadata.log" | Should -BeFalse
    }

    It 'stops before rendering or writing a cache when recovery is unavailable' {
        New-Item -ItemType File -Path "$fixture/unresolved" | Out-Null
        { & $build -DocfxConfig $config -OutputRoot $output -MetadataCache $cache -MetadataCacheKey 'fixture' } |
            Should -Throw '*unresolved project references and recovery was unavailable*metadata.log*'
        Test-Path -LiteralPath "$output/site" | Should -BeFalse
        @(Get-ChildItem -LiteralPath $cache -Filter '*.zip' -Recurse).Count | Should -Be 0
        Get-Content -LiteralPath "$fixture/docfx.log" -Raw | Should -Not -Match '(?m)^build '
    }

    It 'supports one evaluated framework, the build output alias and NoRestore' {
        Set-StrictMode -Version Latest
        $scenario = 'single framework'
        $settings.build.output = 'docs-output'
        ConvertTo-Json $settings -Depth 5 | Set-Content -LiteralPath $config
        & $build -DocfxConfig $config -OutputRoot $output -NoRestore
        Test-Path -LiteralPath "$output/net11/docs-output/api/Library.html" | Should -BeTrue
        Test-Path -LiteralPath "$output/net10" | Should -BeFalse
        Get-Content -LiteralPath "$fixture/dotnet.log" -Raw | Should -Not -Match '(?m)^restore '
    }

    It 'renders with the default destination and metadata when optional keys are absent under StrictMode' {
        Set-StrictMode -Version Latest
        $scenario = 'single framework'
        & $build -DocfxConfig $config -OutputRoot $output

        Test-Path -LiteralPath "$output/net11/_site/api/Library.html" | Should -BeTrue
        $metadata = Get-Content -LiteralPath "$output/net11/framework-metadata.json" -Raw | ConvertFrom-Json -AsHashtable
        $metadata.metadata[0].properties.Configuration | Should -BeExactly 'Release'
        $render = Get-Content -LiteralPath "$output/net11/framework-build.json" -Raw | ConvertFrom-Json -AsHashtable
        $render.build.globalMetadata._frameworkDirectory | Should -BeExactly 'net11'
    }

    It 'diagnoses <scenario>' -ForEach @(
        @{ scenario = 'missing CLI'; expected = '*add its executable to PATH*' }
        @{ scenario = 'CLI version failure'; expected = '*Could not determine the installed DocFX version*' }
        @{ scenario = 'wrong CLI version'; expected = '*found ''2.80.0''*' }
        @{ scenario = 'missing store'; expected = '*mapping libraries were not found*' }
        @{ scenario = 'missing mapping library'; expected = '*mapping library can be found*' }
        @{ scenario = 'missing template entry'; expected = '*Configure one ms-style entry*' }
        @{ scenario = 'missing custom template'; expected = '*configured in docfx.json was not found*' }
        @{ scenario = 'template inside output'; expected = '*outside the ms-style template directory*' }
        @{ scenario = 'stale template contract'; expected = '*framework-views.compat, found ''stale''*' }
        @{ scenario = 'missing template contract'; expected = '*framework-views.compat, found missing or empty*' }
        @{ scenario = 'missing selector script'; expected = '*Missing public/framework-view.js*' }
        @{ scenario = 'invalid output lock'; expected = '*Invalid framework output lock*' }
        @{ scenario = 'resolver failure'; expected = '*dotnet exited with 1*discovery.log*' }
        @{ scenario = 'assembly input'; expected = '*require project inputs*Library.dll*' }
        @{ scenario = 'project inside output'; expected = '*Library.csproj*is inside the framework output*' }
        @{ scenario = 'pinned framework'; expected = '*Remove TargetFramework from the properties*' }
        @{ scenario = 'MSBuild evaluation failure'; expected = '*MSBuild evaluation failed*Library.csproj*' }
        @{ scenario = 'no frameworks'; expected = '*No target frameworks*Library.csproj*' }
        @{ scenario = 'conflicting properties'; expected = '*Use the same metadata properties*Library.csproj*' }
        @{ scenario = 'empty mapping'; expected = '*No project matched metadata destination*' }
        @{ scenario = 'project SDK failure'; expected = '*Could not determine the selected .NET SDK*' }
        @{ scenario = 'different shared assets'; expected = '*Cannot share public/shared.js with net-10.0*' }
    ) {
        switch ($scenario) {
            'missing store' { Rename-Item -LiteralPath "$fixture/.store" -NewName 'unused-store' }
            'missing mapping library' { Remove-Item -LiteralPath "$store/Docfx.Glob.dll" }
            'missing template entry' { $settings.build.template = @('default') }
            'missing custom template' { $settings.build.template = @('custom/ms-style') }
            'template inside output' {
                $settings.build.template = @((New-Item -ItemType Directory -Path "$output/ms-style").FullName)
            }
            { $_ -in 'stale template contract', 'missing template contract', 'missing selector script' } {
                $template = (New-Item -ItemType Directory -Path "$fixture/custom/ms-style").FullName
                $settings.build.template = @($template)
                if ($scenario -eq 'stale template contract') { Set-Content -LiteralPath "$template/framework-views.compat" 'stale' }
                if ($scenario -eq 'missing selector script') {
                    Set-Content -LiteralPath "$template/framework-views.compat" 'framework-views-v1/docfx-2.81.0'
                }
            }
            'invalid output lock' { New-Item -ItemType Directory -Path "$output/.docfx-framework-views.lock" | Out-Null }
            'pinned framework' { $settings.metadata[0].properties = @{ TargetFramework = 'net11.0' } }
            'conflicting properties' { $settings.metadata += @{ dest = 'api/other'; properties = @{ Configuration = 'Debug' } } }
        }
        ConvertTo-Json $settings -Depth 5 | Set-Content -LiteralPath $config
        { & $build -DocfxConfig $config -OutputRoot $output } | Should -Throw $expected
    }
}
