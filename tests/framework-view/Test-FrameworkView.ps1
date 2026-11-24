#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $BuilderImage = 'docfx-framework-view:test',
    [string] $NginxImage = 'dhi.io/nginx:1.31-alpine',
    [string] $ActionPath,
    [switch] $SkipImageBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "docfx-browser-$([guid]::NewGuid().ToString('N'))"
$output = "$work/output"
$container = $null
$previousOrigin = $env:DOCFX_TEST_ORIGIN
New-Item -ItemType Directory -Path $work | Out-Null
try {
    if (!$ActionPath) {
        $ActionPath = "$work/action"
        git clone -q https://github.com/codebeltnet/docfx-oci-build.git $ActionPath
        git -C $ActionPath checkout -q --detach c297fe0fb8d428a0b400ebcf888a9ec5ff61105c
    }
    if (!$SkipImageBuild) {
        docker build -t $BuilderImage $repo
    }
    Copy-Item -LiteralPath "$PSScriptRoot/fixture" -Destination "$work/fixture" -Recurse
    @{
        apiPath = 'api'
        defaultFramework = 'net11.0'
        builderImage = $BuilderImage
    } | ConvertTo-Json | Set-Content -LiteralPath "$work/fixture/framework-views.json"

    & "$ActionPath/scripts/Build-DocfxFrameworkViews.ps1" -DocfxConfig "$work/fixture/docfx.json" `
        -SettingsPath "$work/fixture/framework-views.json" -OutputRoot $output

    # Reuse the native .NET 10 metadata to render an ordinary site with the packaged template.
    $single = "$work/single"
    New-Item -ItemType Directory -Path $single | Out-Null
    Copy-Item -LiteralPath "$output/net10/api", "$work/fixture/index.md", "$work/fixture/toc.yml" -Destination $single -Recurse
    $build = (Get-Content -LiteralPath "$work/fixture/docfx.json" -Raw | ConvertFrom-Json -AsHashtable).build
    $build.template[2] = '/opt/docfx/templates/ms-style'
    @{ build = $build } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath "$single/docfx.json"
    docker run --rm --mount "type=bind,source=$single,target=/stage" -w /stage $BuilderImage docfx build docfx.json --warningsAsErrors
    Copy-Item -LiteralPath "$single/_site" -Destination "$output/site/single" -Recurse

    $container = docker run --rm -d -p 127.0.0.1::8080 `
        --mount "type=bind,source=$output/site,target=/usr/share/nginx/html,readonly" `
        --mount "type=bind,source=$output/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly" $NginxImage
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
