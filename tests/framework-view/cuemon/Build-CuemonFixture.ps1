#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConsumerRoot,
    [Parameter(Mandatory)][string] $OutputRoot,
    [string] $MetadataCache,
    [string] $MetadataCacheKey,
    [switch] $ForceMetadata
)

$ErrorActionPreference = 'Stop'
$consumer = (Resolve-Path -LiteralPath $ConsumerRoot).Path
$source = "$consumer/.docfx"

# Use the authored inputs for the two-project fixture. The shared script owns discovery and generation.
$config = Get-Content -LiteralPath "$source/docfx.json" -Raw | ConvertFrom-Json -AsHashtable
$group = @($config.metadata | Where-Object dest -CEQ 'api/dotnet')
if ($group.Count -ne 1 -or $group[0].src.Count -ne 1) { throw 'Expected one api/dotnet metadata group with one source mapping.' }
$config.metadata = $group
$mapping = $group[0].src[0]
$mapping.src = [IO.Path]::GetFullPath($mapping.src, $source)
$mapping.files = @($mapping.files | Where-Object { $_ -cmatch '^Cuemon\.(Kernel|IO)/' })
if ($mapping.files.Count -ne 2) { throw 'Expected the authored Cuemon.Kernel and Cuemon.IO project mappings.' }
if (!(Test-Path -LiteralPath "$consumer/cuemon.snk" -PathType Leaf)) {
    $group[0].properties = @{ SkipSignAssembly = 'true' }
}
$config.build.Remove('sitemap')
$config.build.Remove('xref')
$config.build.globalMetadata.Remove('_googleAnalyticsTagId')
$config.build.content = @(@{ files = @('api/dotnet/**/*.yml', 'index.md', 'toc.yml') })

$workspace = Join-Path $consumer "cuemon-docfx-input-$([guid]::NewGuid().ToString('N'))"
$inputRoot = Join-Path $workspace 'input'
New-Item -ItemType Directory -Path "$inputRoot/api" -Force | Out-Null
try {
    Copy-Item -LiteralPath "$source/includes", "$source/images", "$source/templates", "$source/index.md", "$source/$($group[0].filter)" -Destination $inputRoot -Recurse
    Copy-Item -LiteralPath "$source/api/namespaces", "$source/api/types" -Destination "$inputRoot/api" -Recurse
    @'
- name: Concept Reference
  href: index.md
- name: .NET API
  href: api/dotnet/Cuemon.IO.yml
'@ | Set-Content -LiteralPath "$inputRoot/toc.yml"
    ConvertTo-Json -InputObject $config -Depth 100 | Set-Content -LiteralPath "$inputRoot/docfx.json"
    & "$source/BuildRunActions.ps1" -OutputRoot "$inputRoot/run-actions"
    & "$PSScriptRoot/../../../framework-views/Build-DocfxFrameworkViews.ps1" `
        -DocfxConfig "$inputRoot/docfx.json" -OutputRoot $OutputRoot `
        -MetadataCache $MetadataCache -MetadataCacheKey $MetadataCacheKey -ForceMetadata:$ForceMetadata
    & "$source/TestRunActions.ps1" -ScriptsRoot "$inputRoot/run-actions" -SiteRoot (Join-Path $OutputRoot 'site')
} finally {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $workspace).Path
    if ([IO.Path]::GetRelativePath($consumer, $resolvedWorkspace) -cmatch '^cuemon-docfx-input-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
    }
}
