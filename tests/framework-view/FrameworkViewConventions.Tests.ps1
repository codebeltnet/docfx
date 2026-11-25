BeforeAll {
    . "$PSScriptRoot/../../framework-views/FrameworkViewConventions.ps1"
}

Describe 'Framework view conventions' {
    It 'derives the deepest common API directory by whole segments' {
        Get-ApiPath @(@{ dest = 'api/dotnet/runtime/v2' }, @{ dest = 'api/dotnet/utility' }) | Should -BeExactly 'api/dotnet'
        Get-ApiPath @(@{ dest = 'api/dotnet' }, @{ dest = 'api/dotnet/utility' }) | Should -BeExactly 'api/dotnet'
        Get-ApiPath @(@{ dest = 'api/dotnet' }) | Should -BeExactly 'api/dotnet'
    }

    It 'rejects missing, malformed, disjoint and reserved destinations' {
        { Get-ApiPath @() } | Should -Throw '*metadata group*'
        foreach ($dest in $null, 1, '/api', '../api', 'api\dotnet', 'api//other', 'api/../other', 'api/', "api`n") {
            { Get-ApiPath @(@{ dest = $dest }) } | Should -Throw '*metadata.dest*'
        }
        foreach ($pair in @(@('api', 'apis/view'), @('api/sub', 'API/sub'))) {
            { Get-ApiPath @(@{ dest = $pair[0] }, @{ dest = $pair[1] }) } | Should -Throw '*no common API directory*'
        }
        { Get-ApiPath @(@{ dest = '_frameworks/api' }) } | Should -Throw '*reserved directory*'
    }

    It 'orders framework families and numeric versions independently of discovery order' {
        $expected = 'net105.0', 'net11.10', 'net11.9', 'net11.0', 'net10.0', 'net9.0',
            'netcoreapp3.1', 'netcoreapp2.10', 'netcoreapp2.9', 'netstandard2.1', 'netstandard2.0', 'net481', 'net48', 'net462'
        $frameworks = foreach ($tfm in $expected[($expected.Count - 1)..0]) { Get-FrameworkView $tfm 'test.csproj' }
        $ordered = @(Get-OrderedFrameworkViews ($frameworks + $frameworks[0]))
        ($ordered.tfm -join ',') | Should -BeExactly ($expected -join ',')
        $ordered[0].directory | Should -BeExactly 'net105'
        $ordered[0].view | Should -BeExactly 'net-105.0'
        $ordered[1].directory | Should -BeExactly 'net11.10'
        $ordered[-1].view | Should -BeExactly 'net462'
    }

    It 'diagnoses unsupported targets with their project' {
        foreach ($tfm in 'net11.0-windows', 'net11.0-android', 'uap10.0', 'net0.0', 'net5', 'net999999999999.0') {
            { Get-FrameworkView $tfm 'test.csproj' } | Should -Throw "*'$tfm'*'test.csproj'*"
        }
    }

    It 'preserves the public mapping of dotted .NET Framework targets' {
        $dotted = Get-FrameworkView 'net4.8' 'test.csproj'
        $compact = Get-FrameworkView 'net48' 'test.csproj'
        $dotted.family | Should -Be $compact.family
        $dotted.version | Should -Be $compact.version
        $dotted.view | Should -BeExactly 'net-4.8'
        $dotted.directory | Should -BeExactly 'net4.8'
    }
}

Describe 'Output ownership and path isolation' {
    It 'compares full path segments and includes the directory itself' {
        Test-PathWithin "$TestDrive/build" "$TestDrive/build" | Should -BeTrue
        Test-PathWithin "$TestDrive/build" "$TestDrive/build/site" | Should -BeTrue
        Test-PathWithin "$TestDrive/build" "$TestDrive/build-cache" | Should -BeFalse
        Test-PathWithin "$TestDrive/build" $TestDrive | Should -BeFalse
    }

    It 'rejects a file or symlink in the output path' {
        $directory = New-Item -ItemType Directory -Path "$TestDrive/target"
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path "$TestDrive/alias" -Target $directory.FullName | Out-Null
        Set-Content -LiteralPath "$TestDrive/file" -Value 'file'
        { Assert-SafeOutputPath "$TestDrive/target/new" } | Should -Not -Throw
        { Assert-SafeOutputPath "$TestDrive/file" } | Should -Throw '*file or link*'
        { Assert-SafeOutputPath "$TestDrive/alias/new" } | Should -Throw '*file or link*'
    }

    It 'accepts empty output and identifies owned entries only' {
        $root = New-Item -ItemType Directory -Path "$TestDrive/output"
        @(Get-FrameworkOutputEntries $root.FullName '.owner' '.lock').Count | Should -Be 0
        Set-Content -LiteralPath "$root/.owner" -Value @('docfx-framework-views-v1', 'site')
        Set-Content -LiteralPath "$root/.lock" -Value ''
        New-Item -ItemType Directory -Path "$root/site" | Out-Null
        @(Get-FrameworkOutputEntries $root.FullName '.owner' '.lock').Name | Should -BeExactly 'site'
    }

    It 'refuses unowned directories, unexpected entries and nested links before cleanup' {
        $root = New-Item -ItemType Directory -Path "$TestDrive/disputed"
        Set-Content -LiteralPath "$root/sentinel" -Value 'authored'
        { Get-FrameworkOutputEntries $root.FullName '.owner' '.lock' } | Should -Throw '*empty or owned*'
        Set-Content -LiteralPath "$root/.owner" -Value 'invalid'
        { Get-FrameworkOutputEntries $root.FullName '.owner' '.lock' } | Should -Throw '*empty or owned*'
        Set-Content -LiteralPath "$root/.owner" -Value @('docfx-framework-views-v1', 'site')
        { Get-FrameworkOutputEntries $root.FullName '.owner' '.lock' } | Should -Throw '*Unexpected item*sentinel*'
        Get-Content -LiteralPath "$root/sentinel" | Should -BeExactly 'authored'
        Set-Content -LiteralPath "$root/.owner" -Value @('docfx-framework-views-v1', 'site', 'sentinel')
        $directory = New-Item -ItemType Directory -Path "$TestDrive/outside"
        New-Item -ItemType Directory -Path "$root/site" | Out-Null
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path "$root/site/linked" -Target $directory.FullName | Out-Null
        { Get-FrameworkOutputEntries $root.FullName '.owner' '.lock' } | Should -Throw '*contains a link*'
    }
}
