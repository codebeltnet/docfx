#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $DocfxConfig = '.docfx/docfx.json',
    [string] $OutputRoot = '.bot/docfx',
    [switch] $NoRestore,
    [switch] $ForceMetadata,
    [string] $MetadataCache,
    [string] $MetadataCacheKey
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. "$PSScriptRoot/FrameworkViewConventions.ps1"
. "$PSScriptRoot/DocfxMetadata.ps1"

function Invoke-Step([string] $Log, [string] $Command, [string[]] $Arguments, [switch] $ReturnExitCode) {
    & $Command @Arguments *> $Log
    if ($ReturnExitCode) { return $LASTEXITCODE }
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $Log -Tail 25 | Write-Host
        throw "$Command exited with $LASTEXITCODE. See $Log"
    }
}

$configPath = (Resolve-Path -LiteralPath $DocfxConfig).Path
$source = Split-Path -Parent $configPath
$work = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot)
if ((Test-PathWithin $source $work) -or (Test-PathWithin $work $source) -or
    (Test-PathWithin $work (Get-Location).ProviderPath) -or (Test-PathWithin $work $PSScriptRoot)) {
    throw 'Place the framework output in a dedicated directory outside the DocFX input directory.'
}
Assert-SafeOutputPath $work
if ($MetadataCache -and !$MetadataCacheKey) { throw 'A metadata cache requires a metadata input fingerprint.' }
if ($MetadataCache) {
    $MetadataCache = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MetadataCache)
    if ((Test-PathWithin $work $MetadataCache) -or (Test-PathWithin $MetadataCache $work) -or
        (Test-PathWithin $source $MetadataCache) -or (Test-PathWithin $MetadataCache $source)) {
        throw 'Use a dedicated metadata cache directory outside the DocFX inputs and framework output.'
    }
    Assert-SafeOutputPath $MetadataCache
}

$config = Read-Json $configPath
$apiPath = Get-ApiPath $config['metadata']
$buildSettings = $config['build'] ?? @{}
$buildDestination = if ($buildSettings['dest']) { $buildSettings['dest'] } elseif ($buildSettings['output']) { $buildSettings['output'] } else { '_site' }
if ($buildDestination -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or $buildDestination -match '(^|/)\.{1,2}(/|$)') {
    throw 'Framework views require a relative DocFX site destination.'
}
$supportedDocfx = '2.81.0'
$docfx = Get-Command docfx -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (!$docfx) { throw "Install DocFX $supportedDocfx as a .NET tool and add its executable to PATH." }
$version = & $docfx --version
if ($LASTEXITCODE -ne 0 -or !$version) { throw 'Could not determine the installed DocFX version.' }
$version = $version.Trim()
if (($version -split '\+', 2)[0] -cne $supportedDocfx) {
    throw "Framework views use DocFX $supportedDocfx for project discovery. Install that CLI version (found '$version')."
}

$frameworkTemplate = @($buildSettings['template'] | Where-Object { $_ -and (Split-Path -Leaf $_) -ceq 'ms-style' })
if ($frameworkTemplate.Count -ne 1) { throw 'Configure one ms-style entry in the DocFX build template list.' }
$templateSource = [IO.Path]::GetFullPath($frameworkTemplate[0], $source)
if (!(Test-Path -LiteralPath $templateSource)) {
    if ($templateSource -cnotin @([IO.Path]::GetFullPath('templates/ms-style', $source), [IO.Path]::GetFullPath('ms-style', $source))) {
        throw "The ms-style template configured in docfx.json was not found at '$templateSource'."
    }
    $templateSource = [IO.Path]::GetFullPath("$PSScriptRoot/../templates/ms-style")
}
if ((Test-PathWithin $templateSource $work) -or (Test-PathWithin $work $templateSource)) {
    throw 'Place the framework output outside the ms-style template directory.'
}
$expectedContract = "framework-views-v1/docfx-$supportedDocfx"
$marker = "$templateSource/framework-views.compat"
$templateContract = if (Test-Path -LiteralPath $marker -PathType Leaf) {
    [IO.File]::ReadAllText($marker).Trim()
}
if ($templateContract -cne $expectedContract) {
    $actualContract = if ($templateContract) { "'$templateContract'" } else { 'missing or empty' }
    throw "Incompatible ms-style template at '$templateSource'. Expected '$expectedContract' in framework-views.compat, found $actualContract."
}
if (!(Test-Path -LiteralPath "$templateSource/public/framework-view.js" -PathType Leaf)) {
    throw "Incompatible ms-style template at '$templateSource'. Missing public/framework-view.js."
}

$store = Join-Path (Split-Path -Parent $docfx) ".store/docfx/$supportedDocfx/docfx/$supportedDocfx/tools"
if (!(Test-Path -LiteralPath $store -PathType Container)) {
    throw "DocFX $supportedDocfx mapping libraries were not found in '$store'. Install DocFX as a global or --tool-path .NET tool."
}
$tools = Get-ChildItem -LiteralPath $store -Filter Docfx.Glob.dll -File -Recurse | Sort-Object {
    [version]($_.Directory.Parent.Name.Substring(3))
} | Select-Object -First 1
if (!$tools) { throw "Install DocFX as a .NET tool so its mapping library can be found in $store." }
$resolver = "$PSScriptRoot/Resolve-DocfxProjects.cs"
$crossTargetReferences = "$PSScriptRoot/KeepCrossTargetReferences.targets"
$ownershipFile = '.docfx-framework-views'
$lockFile = '.docfx-framework-views.lock'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$lockPath = "$work/$lockFile"
$lockItem = Get-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
if ($lockItem -and ($lockItem.PSIsContainer -or ($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
    throw "Invalid framework output lock at '$lockPath'."
}
if (!$lockItem) { $null = Get-FrameworkOutputEntries $work $ownershipFile $lockFile }
$outputLock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $previousOutput = @(Get-FrameworkOutputEntries $work $ownershipFile $lockFile)
    foreach ($entry in $previousOutput) { Remove-Item -LiteralPath $entry.FullName -Recurse -Force }
    Set-Content -LiteralPath "$work/$ownershipFile" -Value @('docfx-framework-views-v1', 'resolver', 'projects.json', 'resolver-sdk.log', 'discovery.log')
    Write-Host "Artifacts: $work"
    $resolvedPath = "$work/projects.json"
    $resolverDirectory = "$work/resolver"
    New-Item -ItemType Directory -Path $resolverDirectory | Out-Null
    # The file-based app needs .NET 10 or later even if the project pins an older SDK.
    Write-Json "$resolverDirectory/global.json" @{ sdk = @{ version = '10.0.100'; rollForward = 'latestMajor'; allowPrerelease = $true } }
    # File-based builds cache their intermediates by source path. Give each invocation its own.
    $stagedResolver = Join-Path $resolverDirectory 'Resolve-DocfxProjects.cs'
    Copy-Item -LiteralPath $resolver -Destination $stagedResolver
    Push-Location $resolverDirectory
    try {
        Invoke-Step "$work/resolver-sdk.log" dotnet @('--version')
        $resolverSdk = (Get-Content -LiteralPath "$work/resolver-sdk.log" -Raw).Trim()
        # OutputRoot may be under the consumer checkout. Apply its MSBuild configuration only to its projects.
        Invoke-Step "$work/discovery.log" dotnet @('run', '--file', $stagedResolver,
            '-p:ImportDirectoryBuildProps=false', '-p:ImportDirectoryBuildTargets=false', '-p:ImportDirectoryPackagesProps=false',
            '--', $tools.DirectoryName, $configPath, $resolvedPath)
    } finally {
        Pop-Location
    }
    Push-Location $source
    try {
        $mappings = Read-Json $resolvedPath
        $projects = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $groups = for ($groupIndex = 0; $groupIndex -lt $config.metadata.Count; $groupIndex++) {
            $group = $config.metadata[$groupIndex]
            if (!$group['properties']) { $group['properties'] = @{} }
            if (!$group.properties.Contains('Configuration')) { $group.properties.Configuration = 'Release' }
            $groupProjects = @(
                foreach ($mapping in $mappings[$groupIndex]) {
                    $root = if ($mapping['source']) { [IO.Path]::GetFullPath($mapping['source'], $source) } else { $source }
                    foreach ($file in $mapping.files) {
                        if ([IO.Path]::GetExtension($file) -notin '.csproj', '.fsproj', '.vbproj') {
                            throw "Framework views require project inputs. Found '$file' in '$($group.dest)'."
                        }
                        $path = [IO.Path]::GetFullPath($file)
                        if (Test-PathWithin $work $path) { throw "Project '$path' is inside the framework output. Move the project or output directory." }
                        $relative = [IO.Path]::GetRelativePath($root, $path).Replace('\', '/')
                        $properties = @($group.properties.GetEnumerator() | ForEach-Object { "-p:$($_.Key)=$($_.Value)" })
                        if ($group.properties.Contains('TargetFramework')) { throw "Remove TargetFramework from the properties for '$($group.dest)'." }
                        if (!$projects.ContainsKey($path)) {
                            $evaluation = & dotnet msbuild $path -nologo -getProperty:TargetFrameworks,TargetFramework @properties
                            if ($LASTEXITCODE -ne 0) { throw "MSBuild evaluation failed for $path." }
                            $evaluated = (Read-MSBuildJson $evaluation $path).Properties
                            $evaluatedTargets = if ($evaluated.TargetFramework) { $evaluated.TargetFramework } else { $evaluated.TargetFrameworks }
                            $targets = @($evaluatedTargets -split ';' | ForEach-Object Trim | Where-Object { $_ } | Select-Object -Unique)
                            if (!$targets.Count) { throw "No target frameworks for $path." }
                            $discovered = @(foreach ($target in $targets) { Get-FrameworkView $target $path })
                            $projects[$path] = @{ targets = $targets; frameworks = $discovered; properties = $properties; id = $projects.Count }
                            Write-Host "$relative declares $($targets -join ', ')"
                        } elseif (($projects[$path].properties -join "`n") -cne ($properties -join "`n")) {
                            throw "Use the same metadata properties for each occurrence of '$path'."
                        }
                        @{ path = $path; root = $root; relative = $relative }
                    }
                }
            )
            if (!$groupProjects.Count) { throw "No project matched metadata destination '$($group.dest)'." }
            @{ config = $group; projects = $groupProjects }
        }

        $views = [ordered]@{}
        foreach ($framework in Get-OrderedFrameworkViews ($projects.Values | ForEach-Object { $_.frameworks })) {
            $view = $framework.view
            $views[$view] = [ordered]@{ tfm = $framework.tfm; directory = $framework.directory; xref = "/xrefmap.yml?view=$view"; projects = @() }
        }
        $generated = @(
            'site', 'nginx.conf'
            foreach ($project in $projects.Values) { "restore-$($project.id).log" }
            foreach ($entry in $views.Values) {
                $entry.directory
                "cache-$($entry.tfm)"
                "generated-$($entry.tfm)"
            }
        )
        Add-Content -LiteralPath "$work/$ownershipFile" -Value $generated

        $sdk = (& dotnet --version).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Could not determine the selected .NET SDK.' }
        if ($MetadataCache) {
            $cacheVersion = @(Get-FileHash -LiteralPath $PSCommandPath, "$PSScriptRoot/FrameworkViewConventions.ps1", "$PSScriptRoot/DocfxMetadata.ps1", $crossTargetReferences, $resolver, $configPath, $resolvedPath | ForEach-Object Hash) -join ':'
            $cacheInputs = "$version/$sdk/$resolverSdk/$cacheVersion/$MetadataCacheKey/$($views.Keys -join ',')"
            $cacheId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($cacheInputs)))
            $cacheRoot = "$MetadataCache/$cacheId"
            New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
        }
        $restored = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($view in $views.Keys) {
            $entry = $views[$view]
            $tfm = $entry.tfm
            $stage = "$work/$($entry.directory)"
            New-Item -ItemType Directory -Path $stage | Out-Null
            foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
                if ($item.Name -in @('.git', 'bin', 'obj', 'wwwroot', '_site', ($buildDestination -split '/')[0])) { continue }
                Copy-Item -LiteralPath $item.FullName -Destination $stage -Recurse -Force
            }
            $metadata = @(
                foreach ($group in $groups) {
                    $original = $group.config
                    $destination = "$stage/$($original.dest)"
                    Clear-StagedMetadata $destination "$source/$($original.dest)/.manifest"
                    $selected = @($group.projects | Where-Object { $tfm -cin $projects[$_.path].targets })
                    if (!$selected.Count) { continue }
                    $entry.projects += @($selected.relative)
                    $metadataGroup = ConvertTo-Json $original -Depth 100 | ConvertFrom-Json -AsHashtable
                    $metadataGroup.src = @($selected | Group-Object root | ForEach-Object { @{ src = $_.Name; files = @($_.Group.relative) } })
                    $metadataGroup.properties.TargetFramework = $tfm
                    $metadataGroup
                }
            )
            $metadataPath = "$stage/framework-metadata.json"
            Write-Json $metadataPath @{ metadata = $metadata }
            $directories = @($metadata | ForEach-Object { "$stage/$($_.dest)" })
            $cacheFile = if ($MetadataCache) { "$cacheRoot/$tfm.zip" }
            $cache = "$work/cache-$tfm"
            $cached = $false
            if (!$ForceMetadata -and $cacheFile -and (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
                try {
                    [IO.Compression.ZipFile]::ExtractToDirectory($cacheFile, $cache)
                    $cachedFingerprint = Get-MetadataFingerprint @($metadata | ForEach-Object { "$cache/$($_.dest)" })
                    $cached = $cachedFingerprint -and $cachedFingerprint -ceq (Get-Content -LiteralPath "$cache/fingerprint" -Raw).Trim()
                } catch {
                    Write-Warning "Metadata cache for $view could not be read: $($_.Exception.Message)"
                }
            }
            if ($cached) {
                foreach ($group in $metadata) {
                    $destination = "$stage/$($group.dest)"
                    New-Item -ItemType Directory -Path $destination -Force | Out-Null
                    Get-ChildItem -LiteralPath "$cache/$($group.dest)" -Force | Copy-Item -Destination $destination -Recurse -Force
                }
                Write-Host "Reused metadata for $view."
                $count = Get-MetadataCount $directories $view
            } else {
                foreach ($group in $metadata) {
                    foreach ($project in Get-MappedProjectPaths $group) {
                        $info = $projects[$project]
                        if (!$NoRestore -and $restored.Add($project)) {
                            Invoke-Step "$work/restore-$($info.id).log" dotnet (@('restore', $project) + $info.properties)
                        }
                    }
                }
                $count = New-DocfxMetadata $metadata $projects $tfm $view $stage $crossTargetReferences $docfx $cacheFile
            }

            $build = ConvertTo-Json $buildSettings -Depth 100 | ConvertFrom-Json -AsHashtable
            if (!$build['globalMetadata']) { $build['globalMetadata'] = @{} }
            $build.globalMetadata._frameworkApi = $ApiPath
            $build.globalMetadata._frameworkDirectory = $entry.directory
            $build.dest = $buildDestination
            $build.Remove('output')
            $build.template = @($build.template | ForEach-Object {
                if ($_ -ceq $frameworkTemplate[0]) { 'framework-template/ms-style' } else { $_ }
            })
            New-Item -ItemType Directory -Path "$stage/framework-template" | Out-Null
            Copy-Item -LiteralPath $templateSource -Destination "$stage/framework-template/ms-style" -Recurse
            Write-Json "$stage/framework-build.json" @{ build = $build }
            Invoke-Step "$stage/build.log" $docfx @('build', "$stage/framework-build.json")
            Write-Host "$view rendered $count metadata UIDs"
        }
    } finally {
        Pop-Location
    }

    $defaultView = @($views.Keys)[0]
    $site = "$work/site"
    Copy-Item -LiteralPath "$work/$($views[$defaultView].directory)/$buildDestination" -Destination $site -Recurse
    $routes = foreach ($view in $views.Keys) {
        $directory = $views[$view].directory
        if ($view -ceq $defaultView) {
            '    ~^{0}$ "";' -f [regex]::Escape($view)
            continue
        }
        $native = "$work/$directory/$buildDestination"
        $destination = "$site/_frameworks/$directory"
        New-Item -ItemType Directory -Path (Split-Path -Parent "$destination/$ApiPath") | Out-Null
        Copy-Item -LiteralPath "$native/$ApiPath" -Destination "$destination/$ApiPath" -Recurse
        Copy-Item -LiteralPath "$native/xrefmap.yml" -Destination $destination
        if (Test-Path -LiteralPath "$native/index.json" -PathType Leaf) { Copy-Item -LiteralPath "$native/index.json" -Destination $destination }
        foreach ($asset in Get-ChildItem -LiteralPath $native -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($native, $asset.FullName).Replace('\', '/')
            if ($relative.StartsWith("$ApiPath/") -or ($relative -notmatch '^public/' -and $asset.Extension -in '.html', '.json', '.yml', '.xml')) { continue }
            if (!(Test-Path -LiteralPath "$site/$relative" -PathType Leaf) -or
                (Get-FileHash -LiteralPath "$site/$relative").Hash -cne (Get-FileHash -LiteralPath $asset.FullName).Hash) {
                throw "Cannot share $relative with $view."
            }
        }
        '    ~^{0}$ /_frameworks/{1};' -f [regex]::Escape($view), $directory
    }
    $searchRoutes = foreach ($view in $views.Keys) {
        $directory = $views[$view].directory
        $root = if ($view -ceq $defaultView) { '""' } else { "/_frameworks/$directory" }
        '    ~^{0}$ {1};' -f [regex]::Escape($directory), $root
    }
    Write-Json "$site/framework-views.json" ([ordered]@{ schemaVersion = 1; apiPath = "/$ApiPath/"; defaultView = $defaultView; viewOrder = @($views.Keys); views = $views })
    (Get-Content -LiteralPath "$PSScriptRoot/framework-views.nginx.conf" -Raw).Replace('__API__', "/$ApiPath/").
        Replace('__VIEWS__', ($routes -join "`n")).Replace('__SEARCH__', ($searchRoutes -join "`n")) | Set-Content -LiteralPath "$work/nginx.conf"
    Write-Host "Site: $site"
} finally {
    $outputLock.Dispose()
}
