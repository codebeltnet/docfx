#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $BuilderImage = 'docfx-framework-view:test',
    [string] $NginxImage,
    [switch] $SkipImageBuild,
    [switch] $ContainerOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "docfx-browser-$([guid]::NewGuid().ToString('N'))"
$output = "$work/output"
$container = $null
$previousOrigin = $env:DOCFX_TEST_ORIGIN

function Copy-Fixture([string] $Destination) {
    Copy-Item -LiteralPath "$PSScriptRoot/fixture" -Destination $Destination -Recurse
    $docs = New-Item -ItemType Directory -Path "$Destination/.docfx"
    Move-Item -LiteralPath "$Destination/docfx.json", "$Destination/index.md", "$Destination/toc.yml" -Destination $docs.FullName
}

function Test-PackagedGenerator {
    $fixture = "$work/container-fixture"
    $destination = "$fixture/.bot/docfx"
    Copy-Fixture $fixture
    New-Item -ItemType Directory -Path "$work/sdk10" | Out-Null
    '{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}' | Set-Content -LiteralPath "$work/sdk10/global.json"
    '{"sdk":{"version":"11.0.100","rollForward":"latestFeature"}}' | Set-Content -LiteralPath "$fixture/global.json"
    $mount = "type=bind,source=$work,target=/workspace"

    Import-Module "$repo/tools/DocfxImage.psm1"
    $expectedDocfx = Get-DocfxDefaultVersion -RootPath $repo
    $pwshVersion = docker run --rm $BuilderImage pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    $docfxVersion = docker run --rm $BuilderImage docfx --version
    $sdk10 = @(docker run --rm --mount $mount -w /workspace/sdk10 $BuilderImage sh -ec 'dotnet --version && dotnet msbuild -nologo -version')
    $sdk11 = docker run --rm --mount $mount -w /workspace/container-fixture $BuilderImage dotnet --version
    if ($pwshVersion -notmatch '^7\.' -or $docfxVersion -notmatch "^$([regex]::Escape($expectedDocfx))(?:\+.+)?$" -or
        $sdk10[0] -notmatch '^10\.' -or $sdk11 -notmatch '^11\.') {
        throw "Unexpected builder toolchain. PowerShell: $pwshVersion. DocFX: $docfxVersion. SDKs: $($sdk10[0]), $sdk11."
    }
    Write-Host "Packaged tools: PowerShell $pwshVersion, DocFX $docfxVersion, .NET $($sdk10[0]) and $sdk11."
    docker run --rm --mount $mount -w /workspace/container-fixture $BuilderImage pwsh -NoProfile -File /opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1
    if (Get-ChildItem -LiteralPath $destination -Filter 'build-*.log' -Recurse) {
        throw 'Ordinary metadata generation ran a recovery compilation.'
    }

    foreach ($project in 'Runtime', 'Utilities', 'ModernApi', 'StandardApi') {
        if (!(Test-Path -LiteralPath "$fixture/$project/obj/project.assets.json" -PathType Leaf)) {
            throw "The packaged generator did not restore '$project'."
        }
    }
    $site = "$destination/site"
    $manifest = Get-Content -LiteralPath "$site/framework-views.json" -Raw | ConvertFrom-Json -AsHashtable
    $expectedViews = [ordered]@{
        'net-11.0' = 'net11'
        'net-10.0' = 'net10'
        'netstandard-2.1' = 'netstandard2.1'
        'netstandard-2.0' = 'netstandard2.0'
        'net48' = 'net48'
    }
    if ($manifest.schemaVersion -ne 1 -or $manifest.defaultView -cne 'net-11.0' -or $manifest.apiPath -cne '/api/' -or
        ($manifest.viewOrder -join ',') -cne ($expectedViews.Keys -join ',')) {
        throw 'The packaged generator did not discover and package the expected views.'
    }
    $nginx = Get-Content -LiteralPath "$destination/nginx.conf" -Raw
    if (!$nginx.Contains('location ^~ /api/') -or !$nginx.Contains('location @framework_fallback') -or
        $nginx -match '__(API|VIEWS|SEARCH|FALLBACK)__') {
        throw 'The packaged generator did not configure the API and fallback routes.'
    }
    $widget = 'api/runtime/FrameworkFixture.Runtime.Widget.html'
    $availability = @{
        $widget = $expectedViews.Keys
        'api/utilities/FrameworkFixture.Utilities.Utility.html' = $expectedViews.Keys
        'api/runtime/FrameworkFixture.Runtime.ModernFeature.html' = 'net-11.0', 'net-10.0'
        'api/runtime/FrameworkFixture.Runtime.StandardFeature.html' = 'netstandard-2.1', 'netstandard-2.0'
        'api/runtime/FrameworkFixture.Runtime.LegacyFeature.html' = 'net48'
        'api/modern/FrameworkFixture.ModernApi.Endpoint.html' = 'net-11.0', 'net-10.0'
        'api/standard/FrameworkFixture.StandardApi.Adapter.html' = 'netstandard-2.1', 'netstandard-2.0'
    }
    foreach ($page in $availability.Keys) {
        $relative = $page.Substring(4)
        $actualSet = $manifest.availability.sets[$manifest.availability.pages[$relative]]
        if (($actualSet -join ',') -cne (@($availability[$page]) -join ',')) {
            throw "Unexpected manifest availability for '$page': $($actualSet -join ',')."
        }
    }
    foreach ($view in $expectedViews.Keys) {
        $directory = $expectedViews[$view]
        $viewRoot = if ($view -ceq $manifest.defaultView) { $site } else { "$site/_frameworks/$directory" }
        $index = Get-Content -LiteralPath "$viewRoot/index.json" -Raw | ConvertFrom-Json -AsHashtable
        $xrefs = Get-Content -LiteralPath "$viewRoot/xrefmap.yml" -Raw
        foreach ($page in $availability.Keys) {
            $published = $view -cin $availability[$page]
            if ((Test-Path -LiteralPath "$viewRoot/$page" -PathType Leaf) -ne $published -or
                $index.Contains($page) -ne $published -or $xrefs.Contains("href: $page") -ne $published) {
                throw "Unexpected native page, search entry or xref availability for '$page' in '$view'."
            }
        }
        if ($manifest.views[$view].directory -cne $directory -or !$nginx.Contains("~^$([regex]::Escape($view))$ ") -or
            !$nginx.Contains("~^$([regex]::Escape($directory))$ ")) {
            throw "Missing API or search routing for '$view'."
        }
    }
    if ((Get-Content -LiteralPath "$site/$widget" -Raw) -notmatch 'id="framework-view"') {
        throw 'The packaged ms-style template did not render the framework selector.'
    }
    Write-Host 'The packaged generator restored both projects and produced all five views, native xrefs, search indexes and NGINX routes.'
}

New-Item -ItemType Directory -Path $work | Out-Null
try {
    if (!$SkipImageBuild) {
        docker build -t $BuilderImage $repo
    }
    Test-PackagedGenerator
    if ($ContainerOnly) { return }

    Copy-Fixture "$work/fixture"
    $docs = "$work/fixture/.docfx"
    & "$repo/framework-views/Build-DocfxFrameworkViews.ps1" -DocfxConfig "$docs/docfx.json" -OutputRoot $output
    foreach ($path in 'site/framework-views.json', 'nginx.conf') {
        $native = (Get-Content -LiteralPath "$output/$path" -Raw).Replace("`r`n", "`n")
        $packaged = (Get-Content -LiteralPath "$work/container-fixture/.bot/docfx/$path" -Raw).Replace("`r`n", "`n")
        if ($native -cne $packaged) { throw "Native and packaged generation differ for '$path'." }
    }

    # Reuse the native .NET 10 metadata to render an ordinary site with the packaged template.
    $single = "$work/single"
    New-Item -ItemType Directory -Path $single | Out-Null
    Copy-Item -LiteralPath "$output/net10/api", "$docs/index.md", "$docs/toc.yml" -Destination $single -Recurse
    $build = (Get-Content -LiteralPath "$docs/docfx.json" -Raw | ConvertFrom-Json -AsHashtable).build
    $build.template[2] = '/opt/docfx/templates/ms-style'
    @{ build = $build } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$single/docfx.json"
    docker run --rm --mount "type=bind,source=$single,target=/stage" -w /stage $BuilderImage docfx build docfx.json
    Copy-Item -LiteralPath "$single/_site" -Destination "$output/site/single" -Recurse

    $imageContext = "$work/image"
    New-Item -ItemType Directory -Path $imageContext | Out-Null
    Move-Item -LiteralPath "$output/site", "$output/nginx.conf" -Destination $imageContext
    $buildArguments = @(
        '--quiet', '--file', "$repo/framework-views/framework-views.Dockerfile"
        if ($NginxImage) { '--build-arg', "NGINX_IMAGE=$NginxImage" }
        $imageContext
    )
    $siteImage = docker build @buildArguments
    $container = docker run --rm -d -p 127.0.0.1::8080 $siteImage
    $endpoint = (docker port $container 8080/tcp).Trim()
    $env:DOCFX_TEST_ORIGIN = "http://$endpoint"
    Push-Location $PSScriptRoot
    try {
        npm test
    } finally {
        Pop-Location
    }
} finally {
    $env:DOCFX_TEST_ORIGIN = $previousOrigin
    if ($container) { docker stop $container | Out-Null }
    Write-Host "Fixture artifacts: $work"
}
