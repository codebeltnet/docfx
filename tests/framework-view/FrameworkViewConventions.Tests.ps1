BeforeAll {
    . "$PSScriptRoot/../../framework-views/FrameworkViewConventions.ps1"
    . "$PSScriptRoot/../../framework-views/DocfxMetadata.ps1"
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

Describe 'Page availability inventory, NGINX fallback rules and shared navigation TOC' {
    It 'derives deterministic deduplicated page availability in framework precedence order' {
        $site = (New-Item -ItemType Directory -Path "$TestDrive/avail-site").FullName
        New-Item -ItemType Directory -Path "$site/api/dotnet", "$site/api/aspnet", "$site/_frameworks/net10/api/dotnet", "$site/_frameworks/net10/api/aspnet", "$site/_frameworks/netstandard2.0/api/dotnet", "$site/_frameworks/net48/api/legacy" -Force | Out-Null
        Set-Content -LiteralPath "$site/api/dotnet/Common.html" 'net11'
        Set-Content -LiteralPath "$site/api/aspnet/Endpoint.html" 'net11'
        Set-Content -LiteralPath "$site/api/aspnet/toc.json" '{}'
        Set-Content -LiteralPath "$site/_frameworks/net10/api/dotnet/Common.html" 'net10'
        Set-Content -LiteralPath "$site/_frameworks/net10/api/aspnet/Endpoint.html" 'net10'
        Set-Content -LiteralPath "$site/_frameworks/netstandard2.0/api/dotnet/Common.html" 'ns20'
        Set-Content -LiteralPath "$site/_frameworks/net48/api/legacy/Legacy.html" 'net48'

        $views = [ordered]@{
            'net-11.0'        = [ordered]@{ directory = 'net11' }
            'net-10.0'        = [ordered]@{ directory = 'net10' }
            'netstandard-2.1' = [ordered]@{ directory = 'netstandard2.1' }
            'netstandard-2.0' = [ordered]@{ directory = 'netstandard2.0' }
            'net48'           = [ordered]@{ directory = 'net48' }
        }

        $availability = Get-FrameworkPageAvailability $site 'api' 'net-11.0' $views
        @($availability.pages.Keys) | Should -BeExactly @('aspnet/Endpoint.html', 'dotnet/Common.html', 'legacy/Legacy.html')
        $availability.sets[$availability.pages['aspnet/Endpoint.html']] | Should -BeExactly @('net-11.0', 'net-10.0')
        $availability.sets[$availability.pages['dotnet/Common.html']] | Should -BeExactly @('net-11.0', 'net-10.0', 'netstandard-2.0')
        $availability.sets[$availability.pages['legacy/Legacy.html']] | Should -BeExactly @('net48')
        $availability.pages.Contains('aspnet/toc.json') | Should -BeFalse

        # Duplicate availability set reuses the same set index.
        Set-Content -LiteralPath "$site/api/aspnet/Second.html" 'net11'
        Set-Content -LiteralPath "$site/_frameworks/net10/api/aspnet/Second.html" 'net10'
        $updated = Get-FrameworkPageAvailability $site 'api' 'net-11.0' $views
        $updated.pages['aspnet/Second.html'] | Should -Be $updated.pages['aspnet/Endpoint.html']
        $updated.sets.Count | Should -Be 3
    }

    It 'generates ordered NGINX fallback rules for default and non-default views' {
        $views = [ordered]@{
            'net-11.0'        = [ordered]@{ directory = 'net11' }
            'netstandard-2.0' = [ordered]@{ directory = 'netstandard2.0' }
        }
        $rules = @(Get-FrameworkNginxFallbackRules 'net-11.0' $views)
        $rules.Count | Should -Be 2
        $rules[0] | Should -BeExactly '        if (-f $document_root$framework_fallback_target) { return 302 $uri?${framework_query_prefix}view=net-11.0; }'
        $rules[1] | Should -BeExactly '        if (-f $document_root/_frameworks/netstandard2.0$framework_fallback_target) { return 302 $uri?${framework_query_prefix}view=netstandard-2.0; }'
    }

    It 'normalizes API page paths and ignores non-API or empty hrefs' {
        Resolve-FrameworkApiRelativePage '' 'api/' | Should -BeNullOrEmpty
        Resolve-FrameworkApiRelativePage 'index.html' 'api/' | Should -BeNullOrEmpty
        Resolve-FrameworkApiRelativePage '/api/dotnet/Common.html?view=net-10.0#top' 'api/' | Should -BeExactly 'dotnet/Common.html'
        Resolve-FrameworkApiRelativePage 'api/legacy/' 'api/' | Should -BeExactly 'legacy/index.html'
        Resolve-FrameworkApiRelativePage 'api/' 'api/' | Should -BeExactly 'index.html'
    }

    It 'resolves reordered siblings to their own destinations' {
        $availability = @{ pages = @{ 'First.html' = 0; 'Second.html' = 0 } }
        $target = @(
            @{ name = 'First API'; href = '/api/First.yml#members' }
            @{ name = 'Second API'; href = 'api/Second.yml' }
        )
        $candidates = , @(
            @{ name = 'Second API'; href = 'api/Second.html' }
            @{ name = 'First API'; href = 'api/First.html#members' }
        )

        Merge-NavigationTocItems $target $candidates 'api/' $availability | Should -BeTrue
        $target[0].href | Should -BeExactly 'api/First.html#members'
        $target[1].href | Should -BeExactly 'api/Second.html'
    }

    It 'leaves a missing intermediate sibling unresolved and matches the following sibling' {
        $availability = @{ pages = @{ 'First.html' = 0; 'Last.html' = 0 } }
        $target = @(
            @{ name = 'First API'; href = 'api/First.html' }
            @{ name = 'Missing API'; href = 'api/Missing.yml' }
            @{ name = 'Last API'; href = 'api/Last.yml' }
        )
        $candidates = , @(
            @{ name = 'First API'; href = 'api/First.html' }
            @{ name = 'Last API'; href = 'api/Last.html' }
        )

        Merge-NavigationTocItems $target $candidates 'api/' $availability | Should -BeTrue
        $target[1].href | Should -BeExactly 'api/Missing.yml'
        $target[2].href | Should -BeExactly 'api/Last.html'
    }

    It 'matches nested entries only within their matched parent and skips unrelated links with the same name' {
        $availability = @{ pages = @{ 'Shared.html' = 0; 'Other.html' = 0; 'Match.html' = 0 } }
        $target = @(
            @{ name = 'Missing Group'; items = @(@{ name = 'Shared'; href = 'api/Shared.yml' }) }
            @{ name = 'Group'; items = @(
                @{ name = 'Shared'; href = 'api/Shared.yml' }
                @{ name = 'Match'; href = 'api/Match.yml' }
            ) }
        )
        $candidates = , @(
            @{ name = 'Other Group'; items = @(@{ name = 'Shared'; href = 'api/Shared.html' }) }
            @{ name = 'Group'; items = @(
                @{ name = 'Match'; href = 'api/Match.html' }
                @{ name = 'Shared'; href = 'api/Other.html' }
            ) }
        )

        Merge-NavigationTocItems $target $candidates 'api/' $availability | Should -BeTrue
        $target[0].items[0].href | Should -BeExactly 'api/Shared.yml'
        $target[1].items[0].href | Should -BeExactly 'api/Shared.yml'
        $target[1].items[1].href | Should -BeExactly 'api/Match.html'
    }

    It 'skips ambiguous sibling identities in either TOC' {
        $availability = @{ pages = @{ 'DuplicateTarget.html' = 0; 'DuplicateCandidate.html' = 0 } }
        $target = @(
            @{ name = 'Duplicate target'; href = 'api/DuplicateTarget.yml' }
            @{ name = 'Duplicate target'; href = 'api/DuplicateTarget.yml' }
            @{ name = 'Duplicate candidate'; href = 'api/DuplicateCandidate.yml' }
        )
        $candidates = , @(
            @{ name = 'Duplicate target'; href = 'api/DuplicateTarget.html' }
            @{ name = 'Duplicate candidate'; href = 'api/DuplicateCandidate.html'; tocHref = 'api/one/toc.html' }
            @{ name = 'Duplicate candidate'; href = 'api/DuplicateCandidate.html'; tocHref = 'api/two/toc.html' }
        )

        Merge-NavigationTocItems $target $candidates 'api/' $availability | Should -BeFalse
        $target.href | Should -BeExactly @('api/DuplicateTarget.yml', 'api/DuplicateTarget.yml', 'api/DuplicateCandidate.yml')
    }

    It 'requires a name and keeps framework precedence among matching available destinations' {
        $availability = @{ pages = @{ 'Section.html' = 0; 'Unnamed.html' = 0 } }
        $target = @(
            @{ name = 'Section'; href = 'api/Section.yml#members' }
            @{ href = 'api/Unnamed.yml' }
        )
        $candidates = @(
            , $null
            , @(
                @{ name = 'Section'; href = 'api/Section.html#examples' }
                @{ name = 'section'; href = 'api/Section.html#members' }
                @{ href = 'api/Unnamed.html' }
            )
            , @(@{ name = 'Section'; href = 'api/Section.yml#members' })
            , @(@{ name = 'Section'; href = '/api/Section.html#members' })
            , @(@{ name = 'Section'; href = 'api/Section.html#members' })
        )

        Merge-NavigationTocItems $target $candidates 'api/' $availability | Should -BeTrue
        $target[0].href | Should -BeExactly '/api/Section.html#members'
        $target[1].href | Should -BeExactly 'api/Unnamed.yml'
    }

    It 'merges unresolved non-default API navigation entries including nested items and handles edge cases' {
        $work = (New-Item -ItemType Directory -Path "$TestDrive/toc-merge").FullName
        $site = (New-Item -ItemType Directory -Path "$work/site").FullName
        $views = [ordered]@{
            'net-11.0'        = [ordered]@{ directory = 'net11' }
            'net-10.0'        = [ordered]@{ directory = 'net10' }
            'netstandard-2.0' = [ordered]@{ directory = 'netstandard2.0' }
            'net48'           = [ordered]@{ directory = 'net48' }
        }
        $availability = [ordered]@{
            sets  = @(, @('net-11.0'), @('netstandard-2.0', 'net48'))
            pages = [ordered]@{
                'dotnet/Common.html' = 0
                'legacy/Legacy.html' = 1
                'nested/Nested.html' = 1
            }
        }

        # Missing toc.json is a no-op.
        Merge-SharedNavigationToc $site $work '_site' 'api' 'net-11.0' $views $availability
        Merge-NavigationTocItems $null @() 'api/' $availability | Should -BeFalse

        # toc.json without items is a no-op.
        Write-Json "$site/toc.json" @{ memberLayout = 'SamePage' }
        Merge-SharedNavigationToc $site $work '_site' 'api' 'net-11.0' $views $availability

        # toc.json with no candidate toc.json files is a no-op.
        Write-Json "$site/toc.json" @{ items = @(@{ name = 'Concept'; href = 'index.html' }) }
        Merge-SharedNavigationToc $site $work '_site' 'api' 'net-11.0' $views $availability

        # Candidate toc.json exists with empty/shorter items and nested items.
        New-Item -ItemType Directory -Path "$work/net10/_site", "$work/netstandard2.0/_site", "$work/net48/_site" -Force | Out-Null
        Write-Json "$work/net10/_site/toc.json" @{ items = @(@{ name = 'Concept'; href = 'index.html' }) }
        Write-Json "$work/netstandard2.0/_site/toc.json" @{
            items = @(
                @{ name = 'Concept'; href = 'index.html' }
                @{ name = '.NET API'; href = 'api/dotnet/Common.html' }
                @{ name = 'Legacy API'; href = 'api/legacy/Legacy.html'; topicHref = 'api/legacy/Legacy.html'; tocHref = 'api/legacy/toc.html' }
                @{ name = 'Group'; items = @(@{ name = 'Nested'; href = 'api/nested/Nested.html' }) }
            )
        }
        Write-Json "$work/net48/_site/toc.json" @{ memberLayout = 'SamePage' }
        Write-Json "$site/toc.json" @{
            items = @(
                @{ name = 'Concept'; href = 'index.html' }
                @{ name = '.NET API'; href = 'api/dotnet/Common.html' }
                @{ name = 'Legacy API'; href = 'api/legacy/Legacy.yml' }
                @{ name = 'Group'; items = @(@{ name = 'Nested'; href = 'api/nested/Nested.yml' }) }
            )
        }

        Merge-SharedNavigationToc $site $work '_site' 'api' 'net-11.0' $views $availability
        $merged = Read-Json "$site/toc.json"
        $merged.items[2].href | Should -BeExactly 'api/legacy/Legacy.html'
        $merged.items[2].topicHref | Should -BeExactly 'api/legacy/Legacy.html'
        $merged.items[2].tocHref | Should -BeExactly 'api/legacy/toc.html'
        $merged.items[3].items[0].href | Should -BeExactly 'api/nested/Nested.html'

        # Re-running when everything is already resolved is an unchanged no-op.
        $before = Get-Content -LiteralPath "$site/toc.json" -Raw
        Merge-SharedNavigationToc $site $work '_site' 'api' 'net-11.0' $views $availability
        Get-Content -LiteralPath "$site/toc.json" -Raw | Should -BeExactly $before
    }
}
