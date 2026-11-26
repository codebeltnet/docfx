function Get-ApiPath($Metadata) {
    if (!$Metadata) { throw 'Configure at least one project metadata group in docfx.json.' }
    $common = $null
    foreach ($group in $Metadata) {
        $destination = $group['dest']
        if ($destination -isnot [string] -or $destination -cnotmatch '^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\z') {
            throw "Invalid metadata.dest '$destination'. Use a relative API directory with forward slashes and URL-safe directory names."
        }
        $segments = $destination.Split('/')
        if ($null -eq $common) {
            $common = $segments
            continue
        }
        $length = 0
        while ($length -lt [Math]::Min($common.Count, $segments.Count) -and $common[$length] -ceq $segments[$length]) {
            $length++
        }
        if (!$length) { throw 'Metadata destinations have no common API directory. Put all metadata.dest paths under one directory in docfx.json.' }
        $common = $common[0..($length - 1)]
    }
    if ($common[0] -in 'public', '_frameworks', '_framework-search') {
        throw "Metadata destinations use the reserved directory '$($common[0])'. Choose a different API directory in docfx.json."
    }
    $common -join '/'
}

function Get-FrameworkView([string] $Tfm, [string] $Project) {
    if ($Tfm -cmatch '^(net)([1-4])([0-9])([0-9]?)$') {
        $patch = if ($Matches[4]) { $Matches[4] } else { '0' }
        return @{ tfm = $Tfm; family = 3; version = [version]("$($Matches[2]).$($Matches[3]).$patch"); view = $Tfm; directory = $Tfm }
    }
    if ($Tfm -cmatch '^(net|netcoreapp|netstandard)(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        $name = $Matches[1]
        $major = $Matches[2]
        $minor = $Matches[3]
        $version = $null
        if ([version]::TryParse("$major.$minor", [ref] $version) -and $version.Major -ge 1) {
            $family = @('net', 'netcoreapp', 'netstandard').IndexOf($name)
            if ($family -eq 0 -and $version.Major -lt 5) {
                $family = 3
                $version = [version]("$major.$minor.0")
            }
            $directory = if ($family -eq 0 -and $version.Minor -eq 0) { "net$major" } else { $Tfm }
            return @{ tfm = $Tfm; family = $family; version = $version; view = "$name-$major.$minor"; directory = $directory }
        }
    }
    throw "Unsupported target framework '$Tfm' in '$Project'. Framework views require unqualified .NET, .NET Core, .NET Standard or .NET Framework TFMs. Check the evaluated project targets and metadata.src mappings in docfx.json."
}

function Get-OrderedFrameworkViews($Frameworks) {
    $Frameworks | Sort-Object { $_.family }, @{ Expression = { $_.version }; Descending = $true }, { $_.tfm } -Unique
}

function Test-PathWithin([string] $Directory, [string] $Path) {
    $relative = [IO.Path]::GetRelativePath($Directory, $Path)
    $relative -ne '..' -and !$relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)") -and ![IO.Path]::IsPathRooted($relative)
}

function Assert-SafeOutputPath([string] $Path) {
    for ($ancestor = $Path; $ancestor; $ancestor = [IO.Path]::GetDirectoryName($ancestor)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw "Framework output requires real directories. '$ancestor' is a file or link."
        }
    }
}

function Get-FrameworkOutputEntries([string] $Path, [string] $OwnershipFile, [string] $LockFile) {
    $entries = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object Name -CNE $LockFile)
    if (!$entries.Count) { return }
    $marker = $entries | Where-Object Name -CEQ $OwnershipFile
    if (!$marker -or $marker.PSIsContainer -or ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-Content -LiteralPath $marker.FullName -TotalCount 1) -cne 'docfx-framework-views-v1') {
        throw "Framework output directory must be empty or owned by the generator. Choose a dedicated directory: $Path"
    }
    $owned = @(Get-Content -LiteralPath $marker.FullName | Select-Object -Skip 1)
    foreach ($entry in $entries | Where-Object Name -CNE $OwnershipFile) {
        if ($entry.Name -cnotin $owned) {
            throw "Unexpected item in the framework output directory. Move '$($entry.FullName)' before rebuilding."
        }
        $entry
    }
    $links = Get-ChildItem -LiteralPath $Path -Force -Recurse -Attributes ReparsePoint | Select-Object -First 1
    if ($links) { throw "Framework output contains a link. Move '$($links.FullName)' before rebuilding." }
}

function Get-FrameworkPageAvailability([string] $SiteRoot, [string] $ApiPath, [string] $DefaultView, $Views) {
    $pageViews = [Collections.Generic.Dictionary[string, Collections.Generic.List[string]]]::new([StringComparer]::Ordinal)
    foreach ($view in $Views.Keys) {
        $viewApiRoot = if ($view -ceq $DefaultView) {
            Join-Path $SiteRoot $ApiPath
        } else {
            Join-Path $SiteRoot "_frameworks/$($Views[$view].directory)/$ApiPath"
        }
        if (!(Test-Path -LiteralPath $viewApiRoot -PathType Container)) { continue }
        foreach ($file in [IO.Directory]::EnumerateFiles($viewApiRoot, '*.html', [IO.SearchOption]::AllDirectories)) {
            $relative = [IO.Path]::GetRelativePath($viewApiRoot, $file).Replace('\', '/')
            if (!$pageViews.ContainsKey($relative)) {
                $pageViews[$relative] = [Collections.Generic.List[string]]::new()
            }
            $pageViews[$relative].Add($view)
        }
    }

    $setIndexes = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $sets = [Collections.Generic.List[string[]]]::new()
    $pages = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
    $sortedKeys = [string[]]$pageViews.Keys
    [Array]::Sort($sortedKeys, [StringComparer]::Ordinal)
    foreach ($relative in $sortedKeys) {
        $available = $pageViews[$relative].ToArray()
        $key = $available -join ','
        if (!$setIndexes.ContainsKey($key)) {
            $setIndexes[$key] = $sets.Count
            $sets.Add($available)
        }
        $pages[$relative] = $setIndexes[$key]
    }
    [ordered]@{ sets = $sets.ToArray(); pages = $pages }
}

function Get-FrameworkNginxFallbackRules([string] $DefaultView, $Views) {
    foreach ($view in $Views.Keys) {
        $prefix = if ($view -ceq $DefaultView) { '' } else { "/_frameworks/$($Views[$view].directory)" }
        '        if (-f $document_root{0}$framework_fallback_target) {{ return 302 $uri?${{framework_query_prefix}}view={1}; }}' -f $prefix, $view
    }
}

function Resolve-FrameworkApiRelativePage([string] $Href, [string] $ApiPrefix) {
    if (!$Href) { return $null }
    $normalized = ($Href -split '[?#]', 2)[0].TrimStart('/')
    if (!$normalized.StartsWith($ApiPrefix, [StringComparison]::Ordinal)) { return $null }
    $relative = $normalized.Substring($ApiPrefix.Length)
    if (!$relative -or $relative.EndsWith('/')) { "${relative}index.html" } else { $relative }
}

function Get-NavigationTocIdentityHref([string] $Href) {
    # DocFX can leave an API source link unresolved in one view and render it as HTML in another.
    $Href -creplace '^/(?!/)', '' -creplace '^([^?#]+)\.yml(?=[?#]|$)', '$1.html'
}

function Merge-NavigationTocItems($TargetItems, $CandidateItemLists, [string] $ApiPrefix, $Availability) {
    $changed = $false
    if (!$TargetItems) { return $false }
    foreach ($item in $TargetItems) {
        $relative = Resolve-FrameworkApiRelativePage $item['href'] $ApiPrefix
        $needsDestination = $relative -and !$Availability.pages.Contains($relative)
        if (!$needsDestination -and !$item['items']) { continue }

        $name = $item['name']
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $identityHref = Get-NavigationTocIdentityHref $item['href']
        $sameIdentity = {
            [string]::Equals($_['name'], $name, [StringComparison]::Ordinal) -and
                [string]::Equals((Get-NavigationTocIdentityHref $_['href']), $identityHref, [StringComparison]::Ordinal)
        }
        if (@($TargetItems | Where-Object $sameIdentity).Count -ne 1) { continue }
        $candidates = @(
            foreach ($candidateList in $CandidateItemLists) {
                if (!$candidateList) { continue }
                $matchingItems = @($candidateList | Where-Object $sameIdentity)
                if ($matchingItems.Count -eq 1) { $matchingItems[0] }
            }
        )

        if ($needsDestination) {
            foreach ($candidate in $candidates) {
                $candidateHref = $candidate['href']
                $candidateRelative = Resolve-FrameworkApiRelativePage $candidateHref $ApiPrefix
                if ($candidateRelative -and $Availability.pages.Contains($candidateRelative)) {
                    $item['href'] = $candidateHref
                    foreach ($field in 'topicHref', 'tocHref') {
                        if ($candidate.Contains($field)) { $item[$field] = $candidate[$field] }
                    }
                    $changed = $true
                    break
                }
            }
        }
        if ($item['items']) {
            $childCandidates = @(
                foreach ($candidate in $candidates) {
                    if ($candidate['items']) { , $candidate['items'] }
                }
            )
            if (Merge-NavigationTocItems $item['items'] $childCandidates $ApiPrefix $Availability) { $changed = $true }
        }
    }
    $changed
}

function Merge-SharedNavigationToc([string] $SiteRoot, [string] $WorkRoot, [string] $BuildDestination, [string] $ApiPath, [string] $DefaultView, $Views, $Availability) {
    $tocPath = Join-Path $SiteRoot 'toc.json'
    if (!(Test-Path -LiteralPath $tocPath -PathType Leaf)) { return }
    $targetToc = Read-Json $tocPath
    if (!$targetToc -or !$targetToc.Contains('items')) { return }
    $candidateLists = @(
        foreach ($view in $Views.Keys) {
            if ($view -ceq $DefaultView) { continue }
            $candidatePath = Join-Path $WorkRoot "$($Views[$view].directory)/$BuildDestination/toc.json"
            if (!(Test-Path -LiteralPath $candidatePath -PathType Leaf)) { continue }
            $candidateToc = Read-Json $candidatePath
            if ($candidateToc -and $candidateToc.Contains('items')) { , $candidateToc['items'] }
        }
    )
    if (!$candidateLists.Count) { return }
    if (Merge-NavigationTocItems $targetToc['items'] $candidateLists "$ApiPath/" $Availability) {
        Write-Json $tocPath $targetToc
    }
}
