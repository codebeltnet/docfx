#requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $ProjectSdk8,
    [switch] $TestRouting,
    [string] $NginxImage = 'dhi.io/nginx:1.31-alpine'
)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) "docfx-framework-test-$([guid]::NewGuid().ToString('N'))"
$docs = "$root/.docfx"
$config = "$docs/docfx.json"
$build = "$PSScriptRoot/../../framework-views/Build-DocfxFrameworkViews.ps1"
$defaultTfm, $otherTfm = if ($ProjectSdk8) { 'net8.0', 'netstandard2.1' } else { 'net11.0', 'net10.0' }
$defaultView, $otherView = $defaultTfm, $otherTfm -creplace '^(net(?:standard)?)(\d)', '$1-$2'
$defaultDirectory = $defaultTfm -replace '\.0$', ''
$otherDirectory = $otherTfm -replace '\.0$', ''
$arguments = @{
    DocfxConfig = $config
    MetadataCache = "$root/cache"
    MetadataCacheKey = 'synthetic-regression'
}

New-Item -ItemType Directory "$root/src/Runtime", "$root/src/Legacy", "$root/src/Excluded", "$root/dependencies/Bridge", "$root/dependencies/Model", $docs | Out-Null
@'
<Project>
  <Target Name="RejectResolver" BeforeTargets="Build" Condition="'$(MSBuildProjectName)' == 'Resolve-DocfxProjects'">
    <Error Text="Framework discovery imported the consumer's Directory.Build.targets." />
  </Target>
</Project>
'@ | Set-Content -LiteralPath "$root/Directory.Build.targets"

if ($ProjectSdk8) {
    Set-Content "$root/global.json" '{"sdk":{"version":"8.0.100","rollForward":"latestFeature"}}'
    Push-Location $docs
    try {
        $projectSdk = & dotnet --version
        if ($LASTEXITCODE -ne 0 -or $projectSdk -notmatch '^8\.') { throw 'The fixture requires a .NET 8 SDK.' }
    } finally {
        Pop-Location
    }
}
$constant = $defaultTfm.ToUpperInvariant().Replace('.', '_')
Set-Content "$root/src/Runtime/Runtime.csproj" @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>$otherTfm;$defaultTfm</TargetFrameworks>
    <LangVersion>latest</LangVersion>
    <AssemblyVersion>3.0.0.0</AssemblyVersion>
  </PropertyGroup>
  <ItemGroup><ProjectReference Include="../../dependencies/Bridge/Bridge.csproj" /></ItemGroup>
</Project>
"@
Set-Content "$root/src/Runtime/Runtime.cs" @"
namespace FrameworkFixture;
public class Common : Compatibility.Bridge { }
#if $constant
public class Modern { }
#endif
"@
foreach ($dependency in 'Bridge', 'Model') {
    $assemblyVersion = if ($dependency -eq 'Bridge') { '7.1.0.0' } else { '12.2.0.0' }
    $projectReference = if ($dependency -eq 'Bridge') { '<ItemGroup><ProjectReference Include="../Model/Model.csproj" /></ItemGroup>' }
    Set-Content "$root/dependencies/$dependency/$dependency.csproj" @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>netstandard2.0</TargetFramework>
    <LangVersion>latest</LangVersion>
    <AssemblyVersion Condition="'`$(DesignTimeBuild)' != 'true'">$assemblyVersion</AssemblyVersion>
  </PropertyGroup>
  $projectReference
</Project>
"@
}
Set-Content "$root/dependencies/Bridge/Bridge.cs" 'namespace FrameworkFixture.Compatibility; public class Bridge : Model { }'
Set-Content "$root/dependencies/Model/Model.cs" 'namespace FrameworkFixture.Compatibility; public class Model { public void InheritedFromModel() { } }'
Set-Content "$root/src/Legacy/Legacy.csproj" "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>$otherTfm</TargetFramework><LangVersion>latest</LangVersion></PropertyGroup></Project>"
Set-Content "$root/src/Legacy/Legacy.cs" 'namespace FrameworkFixture.Compatibility; public class Legacy { }'
Set-Content "$root/src/Excluded/Excluded.csproj" 'This project must be excluded by the DocFX mapping.'
Set-Content "$docs/index.md" '# Shared concept'
@{
    metadata = @(
        @{ src = @(@{ src = '../src'; files = @('**.csproj'); exclude = @('Excluded/**', 'Legacy/**') }); dest = 'reference/runtime' }
        @{ src = @{ src = '../src'; files = 'Legacy/Legacy.csproj' }; dest = 'reference/legacy' }
    )
    build = @{
        content = @(@{ files = @('reference/**/*.yml', 'index.md') })
        globalMetadata = @{ _enableSearch = $true }
        template = @('default', 'modern', 'templates/ms-style')
        dest = 'rendered'
    }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
if (!$ProjectSdk8) {
    $sourceTemplate = "$PSScriptRoot/../../templates/ms-style"
    $override = "$docs/templates/ms-style"
    New-Item -ItemType Directory -Path "$docs/templates" | Out-Null
    Copy-Item -LiteralPath $sourceTemplate -Destination $override -Recurse
    $marker = "$override/framework-views.compat"
    $invalidContracts = @{ stale = 'framework-views-v0/docfx-2.81.0'; empty = '' }
    foreach ($state in $invalidContracts.Keys) {
        [IO.File]::WriteAllText($marker, $invalidContracts[$state])
        $invalidOutput = "$root/incompatible-$state"
        try {
            & $build -DocfxConfig $config -OutputRoot $invalidOutput
            throw "A template override with a $state marker was accepted."
        } catch {
            if ($_.Exception.Message -notlike 'Incompatible ms-style template*framework-views.compat*') { throw }
        }
        if (Test-Path -LiteralPath "$invalidOutput/discovery.log") { throw 'Discovery ran before template validation.' }
    }
    Copy-Item -LiteralPath "$sourceTemplate/framework-views.compat" -Destination $marker -Force
    Write-Host 'Template overrides with stale and empty markers were rejected before discovery.'
}

$fresh = "$root/.bot/docfx"
New-Item -ItemType Directory -Path "$root/.bot" | Out-Null
Set-Content -LiteralPath "$root/.bot/keep.txt" 'unrelated artifact'
Push-Location $root
try {
    & $build -MetadataCache "$root/cache" -MetadataCacheKey $arguments.MetadataCacheKey
} finally {
    Pop-Location
}
if ($ProjectSdk8 -and [version](Get-Content -LiteralPath "$fresh/resolver-sdk.log" -Raw).Trim().Split('-')[0] -lt [version]'10.0') {
    throw 'The resolver did not select a modern SDK independently of the project pin.'
}
$site = "$fresh/site"
$manifest = Get-Content "$site/framework-views.json" -Raw | ConvertFrom-Json
if (($manifest.viewOrder -join ',') -cne "$defaultView,$otherView" -or $manifest.defaultView -cne $defaultView -or $manifest.apiPath -cne '/reference/') {
    throw 'The generated manifest does not reflect the inferred API root and framework precedence.'
}
foreach ($assembly in @(
    @{ path = "$root/src/Runtime/bin/Release/$defaultTfm/Runtime.dll"; version = '3.0.0.0' }
    @{ path = "$root/dependencies/Bridge/bin/Release/netstandard2.0/Bridge.dll"; version = '7.1.0.0' }
    @{ path = "$root/dependencies/Model/bin/Release/netstandard2.0/Model.dll"; version = '12.2.0.0' }
)) {
    if ([Reflection.AssemblyName]::GetAssemblyName($assembly.path).Version -ne [version]$assembly.version) {
        throw "Cross-target metadata generation changed the assembly identity of '$($assembly.path)'."
    }
}
foreach ($directory in $defaultDirectory, $otherDirectory) {
    $metadata = Get-Content -LiteralPath "$fresh/$directory/framework-metadata.json" -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata.metadata[0].properties.Contains('AssemblyVersion') -or
        !(Select-String -LiteralPath "$fresh/$directory/reference/runtime/FrameworkFixture.Common.yml" -SimpleMatch 'FrameworkFixture.Compatibility.Model.InheritedFromModel' -Quiet)) {
        throw "Cross-target metadata for '$directory' lost the native dependency identity or inherited API."
    }
}
foreach ($path in 'index.html', 'reference/runtime/FrameworkFixture.Modern.html', "_frameworks/$otherDirectory/reference/legacy/FrameworkFixture.Compatibility.Legacy.html", "_frameworks/$otherDirectory/reference/runtime/FrameworkFixture.Common.html", "_frameworks/$otherDirectory/index.json") {
    if (!(Test-Path -LiteralPath "$site/$path" -PathType Leaf)) { throw "Missing '$path'." }
}
foreach ($path in 'reference/legacy/FrameworkFixture.Compatibility.Legacy.html', "_frameworks/$otherDirectory/reference/runtime/FrameworkFixture.Modern.html") {
    if (Test-Path -LiteralPath "$site/$path") { throw "Unexpected '$path'." }
}

$expectedHashes = @{}
foreach ($path in 'xrefmap.yml', "_frameworks/$otherDirectory/xrefmap.yml", 'framework-views.json') {
    $expectedHashes[$path] = (Get-FileHash -LiteralPath "$site/$path").Hash
}
& $build @arguments -OutputRoot $fresh
if (Get-ChildItem -LiteralPath $fresh -Filter metadata.log -Recurse) { throw 'The second build did not reuse all metadata.' }
foreach ($path in $expectedHashes.Keys) {
    if ((Get-FileHash -LiteralPath "$site/$path").Hash -cne $expectedHashes[$path]) {
        throw "Cached and fresh output differ for '$path'."
    }
}
if ((Get-Content -LiteralPath "$root/.bot/keep.txt") -cne 'unrelated artifact' -or (Test-Path "$docs/framework-views.json")) {
    throw 'Rebuilding changed unrelated artifacts or authored configuration.'
}

Set-Content -LiteralPath (Get-ChildItem -LiteralPath "$root/cache" -Filter "$defaultTfm.zip" -Recurse).FullName 'invalid cache'
& $build @arguments -OutputRoot "$root/recovered"
if (!(Test-Path -LiteralPath "$root/recovered/$defaultDirectory/metadata.log") -or (Test-Path -LiteralPath "$root/recovered/$otherDirectory/metadata.log")) {
    throw 'The damaged cache did not trigger an isolated metadata rebuild.'
}

Add-Content -LiteralPath "$root/src/Runtime/Runtime.cs" -Value 'public class AddedAfterCache { }'
$arguments.MetadataCacheKey = (Get-FileHash -LiteralPath "$root/src/Runtime/Runtime.cs").Hash
& $build @arguments -OutputRoot "$root/invalidated"
foreach ($directory in $defaultDirectory, $otherDirectory) {
    if (!(Test-Path -LiteralPath "$root/invalidated/$directory/metadata.log") -or
        !(Test-Path -LiteralPath "$root/invalidated/$directory/rendered/reference/runtime/FrameworkFixture.AddedAfterCache.html")) {
        throw "A changed source fingerprint did not invalidate metadata for '$directory'."
    }
}

if ($TestRouting) {
    Set-Content "$site/reference/runtime/index.html" 'default API index'
    Set-Content "$site/_frameworks/$otherDirectory/reference/runtime/index.html" 'other API index'
    Set-Content "$site/_frameworks/$otherDirectory/reference/legacy/index.html" 'other legacy index'
    $mounts = @('--mount', "type=bind,source=$site,target=/usr/share/nginx/html,readonly",
        '--mount', "type=bind,source=$fresh/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly")
    & docker run --rm @mounts $NginxImage -t
    if ($LASTEXITCODE -ne 0) { throw 'Generated NGINX configuration is invalid.' }
    $container = & docker run --rm -d -p 127.0.0.1::8080 @mounts $NginxImage
    if ($LASTEXITCODE -ne 0) { throw 'Could not start NGINX for routing checks.' }
    try {
        $endpoint = (& docker port $container 8080/tcp).Trim()
        if ($LASTEXITCODE -ne 0 -or $endpoint -notmatch '^127\.0\.0\.1:\d+$') { throw 'Could not resolve the test origin.' }
        $responses = @(
            @{ path = '/reference/runtime/'; status = 200; body = 'default API index' }
            @{ path = "/reference/runtime/?view=$defaultView"; status = 200; body = 'default API index' }
            @{ path = "/reference/runtime/?view=$otherView"; status = 200; body = 'other API index' }
            @{ path = "/reference/runtime/index.html?view=$otherView"; status = 200; body = 'other API index' }
            @{ path = "/reference/runtime/FrameworkFixture.Common.html?view=$otherView"; status = 200; body = 'FrameworkFixture' }
            @{ path = '/reference/runtime/?view=unknown'; status = 400; body = 'Unknown documentation view.' }
            @{ path = "/reference/runtime/FrameworkFixture.Modern.html?view=$otherView"; status = 404 }
            @{ path = '/reference/legacy/'; status = 404 }
            @{ path = "/reference/legacy/?view=$otherView"; status = 200; body = 'other legacy index' }
        )
        foreach ($expected in $responses) {
            $result = Invoke-WebRequest "http://$endpoint$($expected.path)" -SkipHttpErrorCheck -MaximumRedirection 0
            $body = if ($result.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($result.Content) } else { $result.Content }
            if ($result.StatusCode -ne $expected.status -or ($expected.body -and !$body.Contains($expected.body)) -or
                $result.Headers['Cache-Control'] -notlike '*no-store*' -or $result.Headers['ETag']) {
                throw "Unexpected routing or caching for '$($expected.path)' (HTTP $($result.StatusCode))."
            }
        }
    } finally {
        & docker stop $container | Out-Null
    }
    Write-Host 'Generated NGINX file and directory routing passed.'
}
Write-Host "Framework build, exclusions, independent groups, cache reuse, recovery and invalidation passed in $root."
