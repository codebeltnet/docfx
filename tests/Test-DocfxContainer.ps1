#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Image,
    [ValidateSet('linux/amd64', 'linux/arm64')][string] $Platform = 'linux/amd64',
    [string] $DocfxVersion,
    [string] $EngineVersion,
    [string] $Revision,
    [string] $SourceRepository = 'https://github.com/codebeltnet/docfx',
    [switch] $RequireNative
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $repoRoot 'tools/DocfxImage.psm1') -Force

if (-not $DocfxVersion) {
    $DocfxVersion = Get-DocfxDefaultVersion -RootPath $repoRoot
}

$expectedArch = ($Platform -split '/')[1]
$expectedRuntimeArch = if ($expectedArch -ceq 'amd64') { 'X64' } else { 'Arm64' }
$expectedCompat = "framework-views-v1/docfx-$DocfxVersion"

if ($RequireNative) {
    Assert-NativeDockerHost -Platform $Platform
}

function Invoke-ContainerCommand {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = (@($output) | ForEach-Object { $_.ToString() }) -join "`n"
        throw "docker $($Arguments -join ' ') failed with exit code $LASTEXITCODE`:`n$text"
    }
    @($output | ForEach-Object { $_.ToString() })
}

Write-Host "Validating DocFX builder image '$Image' on $Platform (DocFX $DocfxVersion, engine '$EngineVersion')..."

# 1. OCI image metadata and architecture
$inspect = (Invoke-ContainerCommand @('image', 'inspect', $Image)) -join "`n" | ConvertFrom-Json
$info = @($inspect)[0]
if ($info.Os -cne 'linux' -or $info.Architecture -cne $expectedArch) {
    throw "Image OS/architecture mismatch: expected linux/$expectedArch, found $($info.Os)/$($info.Architecture)."
}

$labels = $info.Config.Labels
if ($labels.'net.codebelt.docfx.cli.version' -cne $DocfxVersion) {
    throw "Image label net.codebelt.docfx.cli.version expected '$DocfxVersion', found '$($labels.'net.codebelt.docfx.cli.version')'."
}
if ($labels.'org.opencontainers.image.source' -cne $SourceRepository) {
    throw "Image label org.opencontainers.image.source expected '$SourceRepository', found '$($labels.'org.opencontainers.image.source')'."
}
if ($EngineVersion) {
    if ($labels.'org.opencontainers.image.version' -cne $EngineVersion -or
        $labels.'net.codebelt.docfx.engine.version' -cne $EngineVersion) {
        throw "Image engine version labels do not match expected '$EngineVersion'."
    }
}
if ($Revision) {
    if ($labels.'org.opencontainers.image.revision' -cne $Revision) {
        throw "Image label org.opencontainers.image.revision expected '$Revision', found '$($labels.'org.opencontainers.image.revision')'."
    }
}
if ([string]::IsNullOrWhiteSpace($labels.'org.opencontainers.image.created')) {
    throw 'Image label org.opencontainers.image.created is missing.'
}

# 2. PowerShell 7, native runtime CPU architecture, DocFX CLI version, and included .NET SDKs
$pwshInfo = (Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, $Image, 'pwsh', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString() + "|" + [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture')) -join ''
$pwshVersion, $runtimeArch = $pwshInfo.Trim().Split('|', 2)
if ($pwshVersion -notmatch '^7\.' -or $runtimeArch -cne $expectedRuntimeArch) {
    throw "Unexpected PowerShell or process architecture: '$pwshInfo' (expected PowerShell 7 on $expectedRuntimeArch)."
}

$docfxActual = ((Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, $Image, 'docfx', '--version')) -join '').Trim()
if (($docfxActual -split '\+', 2)[0] -cne $DocfxVersion) {
    throw "Unexpected DocFX CLI version '$docfxActual'; expected '$DocfxVersion'."
}

$sdkLines = Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, $Image, 'dotnet', '--list-sdks')
$sdkMajors = @($sdkLines | ForEach-Object { if ($_ -match '^(\d+)\.') { $Matches[1] } } | Select-Object -Unique)
if ('10' -cnotin $sdkMajors -or '11' -cnotin $sdkMajors) {
    throw "Expected both .NET 10 and .NET 11 SDKs in the builder image; found: $($sdkLines -join '; ')."
}

# 3. Template compatibility and complete framework-views generator distribution
$distributionCheck = @'
$ErrorActionPreference = 'Stop'
$requiredFiles = @(
    '/opt/docfx/templates/default',
    '/opt/docfx/templates/modern',
    '/opt/docfx/templates/ms-style/framework-views.compat',
    '/opt/docfx/templates/ms-style/public/framework-view.js',
    '/build/docfx/templates/ms-style/framework-views.compat',
    '/opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1',
    '/opt/docfx/framework-views/FrameworkViewConventions.ps1',
    '/opt/docfx/framework-views/DocfxMetadata.ps1',
    '/opt/docfx/framework-views/Resolve-DocfxProjects.cs',
    '/opt/docfx/framework-views/KeepCrossTargetReferences.targets',
    '/opt/docfx/framework-views/framework-views.nginx.conf',
    '/opt/docfx/framework-views/framework-views.Dockerfile'
)
foreach ($item in $requiredFiles) {
    if (!(Test-Path -LiteralPath $item)) { throw "Missing packaged asset: $item" }
}
(Get-Content -LiteralPath '/opt/docfx/templates/ms-style/framework-views.compat' -Raw).Trim()
'@
$actualCompat = ((Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, $Image, 'pwsh', '-NoProfile', '-Command', $distributionCheck)) -join '').Trim()
if ($actualCompat -cne $expectedCompat) {
    throw "Packaged ms-style compatibility marker expected '$expectedCompat', found '$actualCompat'."
}

# 4. Representative multi-framework build, discovery, metadata, manifest, NGINX config, and single-framework build
$work = Join-Path ([IO.Path]::GetTempPath()) ('docfx-container-test-' + [guid]::NewGuid().ToString('N'))
$mount = "type=bind,source=$work,target=/workspace"
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $fixture = Join-Path $work 'fixture'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'tests/framework-view/fixture') -Destination $fixture -Recurse
    $docs = New-Item -ItemType Directory -Path (Join-Path $fixture '.docfx')
    Move-Item -LiteralPath (Join-Path $fixture 'docfx.json'), (Join-Path $fixture 'index.md'), (Join-Path $fixture 'toc.yml') -Destination $docs.FullName

    New-Item -ItemType Directory -Path (Join-Path $work 'sdk10') | Out-Null
    '{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}' | Set-Content -LiteralPath (Join-Path $work 'sdk10/global.json')
    '{"sdk":{"version":"11.0.100","rollForward":"latestFeature"}}' | Set-Content -LiteralPath (Join-Path $fixture 'global.json')

    $sdk10 = Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, '--mount', $mount, '-w', '/workspace/sdk10', $Image, 'sh', '-ec', 'dotnet --version && dotnet msbuild -nologo -version')
    $sdk11 = (Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, '--mount', $mount, '-w', '/workspace/fixture', $Image, 'dotnet', '--version')) -join ''
    if ($sdk10[0] -notmatch '^10\.' -or $sdk11.Trim() -notmatch '^11\.') {
        throw "global.json SDK selection failed inside builder image: SDK10=$($sdk10[0]), SDK11=$sdk11."
    }

    $null = Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, '--mount', $mount, '-w', '/workspace/fixture', $Image, 'pwsh', '-NoProfile', '-File', '/opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1')

    $destination = Join-Path $fixture '.bot/docfx'
    if (Get-ChildItem -LiteralPath $destination -Filter 'build-*.log' -Recurse) {
        throw 'Ordinary multi-framework metadata generation unexpectedly triggered a recovery build.'
    }
    foreach ($project in 'Runtime', 'Utilities') {
        if (!(Test-Path -LiteralPath (Join-Path $fixture "$project/obj/project.assets.json") -PathType Leaf)) {
            throw "Packaged generator did not restore '$project'."
        }
    }

    $site = Join-Path $destination 'site'
    $manifest = Get-Content -LiteralPath (Join-Path $site 'framework-views.json') -Raw | ConvertFrom-Json -AsHashtable
    $expectedViews = [ordered]@{
        'net-11.0'        = 'net11'
        'net-10.0'        = 'net10'
        'netstandard-2.1' = 'netstandard2.1'
        'netstandard-2.0' = 'netstandard2.0'
        'net48'           = 'net48'
    }
    if ($manifest.schemaVersion -ne 1 -or
        $manifest.defaultView -cne 'net-11.0' -or
        $manifest.apiPath -cne '/api/' -or
        ($manifest.viewOrder -join ',') -cne ($expectedViews.Keys -join ',')) {
        throw 'Generated framework-views.json runtime manifest does not match expected views and precedence.'
    }

    $nginx = Get-Content -LiteralPath (Join-Path $destination 'nginx.conf') -Raw
    if (-not $nginx.Contains('location ^~ /api/') -or $nginx -match '__(API|VIEWS|SEARCH)__') {
        throw 'Generated NGINX configuration is incomplete or contains unsubstituted placeholders.'
    }

    $widget = 'api/runtime/FrameworkFixture.Runtime.Widget.html'
    $availability = @{
        $widget                                                = @($expectedViews.Keys)
        'api/utilities/FrameworkFixture.Utilities.Utility.html' = @($expectedViews.Keys)
        'api/runtime/FrameworkFixture.Runtime.ModernFeature.html' = @('net-11.0', 'net-10.0')
        'api/runtime/FrameworkFixture.Runtime.LegacyFeature.html' = @('net48')
    }
    foreach ($view in $expectedViews.Keys) {
        $directory = $expectedViews[$view]
        $viewRoot = if ($view -ceq $manifest.defaultView) { $site } else { Join-Path $site "_frameworks/$directory" }
        $index = Get-Content -LiteralPath (Join-Path $viewRoot 'index.json') -Raw | ConvertFrom-Json -AsHashtable
        $xrefs = Get-Content -LiteralPath (Join-Path $viewRoot 'xrefmap.yml') -Raw
        foreach ($page in $availability.Keys) {
            $published = $view -cin $availability[$page]
            if ((Test-Path -LiteralPath (Join-Path $viewRoot $page) -PathType Leaf) -ne $published -or
                $index.Contains($page) -ne $published -or
                $xrefs.Contains("href: $page") -ne $published) {
                throw "Unexpected page, search index, or xref availability for '$page' in '$view'."
            }
        }
        if ($manifest.views[$view].directory -cne $directory -or
            -not $nginx.Contains("~^$([regex]::Escape($view))$ ") -or
            -not $nginx.Contains("~^$([regex]::Escape($directory))$ ")) {
            throw "Missing NGINX API or search route for '$view'."
        }
    }

    if ((Get-Content -LiteralPath (Join-Path $site $widget) -Raw) -notmatch 'id="framework-view"') {
        throw 'Packaged ms-style template did not render the framework selector.'
    }

    # Verify ordinary single-framework docfx build using packaged templates
    $single = Join-Path $work 'single'
    New-Item -ItemType Directory -Path $single -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $destination 'net10/api'), (Join-Path $docs 'index.md'), (Join-Path $docs 'toc.yml') -Destination $single -Recurse
    $buildCfg = (Get-Content -LiteralPath (Join-Path $docs 'docfx.json') -Raw | ConvertFrom-Json -AsHashtable).build
    $buildCfg.template[2] = '/opt/docfx/templates/ms-style'
    @{ build = $buildCfg } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $single 'docfx.json')
    $null = Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, '--mount', $mount, '-w', '/workspace/single', $Image, 'docfx', 'build', 'docfx.json')
    if (!(Test-Path -LiteralPath (Join-Path $single '_site/index.html') -PathType Leaf)) {
        throw 'Ordinary single-framework docfx build did not produce _site/index.html.'
    }
} finally {
    if (Test-Path -LiteralPath $work) {
        if ($IsLinux) {
            # The packaged CLI runs as root. Return ownership of its bind-mounted outputs to the runner.
            $owner = "$(& id -u):$(& id -g)"
            $null = Invoke-ContainerCommand @('run', '--rm', '--platform', $Platform, '--mount', $mount, $Image, 'chown', '-Rh', $owner, '/workspace')
        }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Write-Host "PASS: Native container validation passed on $Platform ($runtimeArch): PowerShell $pwshVersion, DocFX $docfxActual, .NET $($sdk10[0]) & $($sdk11.Trim()), 5 framework views + single-framework build."
