#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Workspace,
    [string] $CompareWorkspace,
    [string] $Origin,
    [string] $NginxImage = 'dhi.io/nginx:1.31-alpine'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$workspace = (Resolve-Path -LiteralPath $Workspace).Path
$site = "$workspace/site"
$legacy = 'System.Runtime.CompilerServices.CallerArgumentExpressionAttribute'
$buffer = 'Cuemon.IO.BufferWriterOptions'
$factory = 'Cuemon.IO.StreamFactory'
$aspnetNamespace = 'Cuemon.AspNetCore'
$dotnetBaselineUids = @{ 'net11.0' = 557; 'net10.0' = 557; 'netstandard2.1' = 76; 'netstandard2.0' = 548 }
$aspnetBaselineUids = @{ 'net11.0' = 380; 'net10.0' = 380; 'netstandard2.1' = 0; 'netstandard2.0' = 0 }

function Assert-True([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw $Message }
}

function Read-Json([string] $Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Get-Fingerprint([string] $Root) {
    $entries = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $name = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        if ($name -ceq 'manifest.json') {
            $value = Read-Json $file.FullName
            $value.Remove('source_base_path')
            $value.files = @($value.files | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 30 -Compress } | Sort-Object -CaseSensitive)
            $content = ConvertTo-Json -InputObject $value -Depth 30 -Compress
        } elseif ($file.Name -ceq 'index.json') {
            $index = Read-Json $file.FullName
            $content = ($index.Keys | Sort-Object -CaseSensitive | ForEach-Object {
                "$_ " + (ConvertTo-Json -InputObject $index[$_] -Depth 20 -Compress)
            }) -join [char]10
        } elseif ($file.Extension -cin '.html', '.yml', '.json', '.js', '.css', '.ps1', '.svg', '.map' -or $file.Name -ceq '.manifest') {
            $content = [IO.File]::ReadAllText($file.FullName).Replace([string]([char]13) + [char]10, [string][char]10)
            if ($content.StartsWith('### YamlMime:ManagedReference')) {
                # Match the repository-relative source path DocFX uses to render the source link.
                $content = $content -creplace '(?m)(^  source:\n    remote:\n      path: (\S+)\n      branch: [^\n]+\n      repo: [^\n]+\n    id: [^\n]+\n    path: )(?:[^\n]*/)?\2$', '$1$2'
            }
        } else {
            $entries.Add($name, (Get-FileHash -LiteralPath $file.FullName).Hash)
            continue
        }
        $entries.Add($name, [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($content))))
    }
    $entries
}

function Compare-Trees([string] $Left, [string] $Right) {
    $leftHashes = Get-Fingerprint $Left
    $rightHashes = Get-Fingerprint $Right
    $differences = @($leftHashes.Keys | Where-Object { $leftHashes[$_] -cne $rightHashes[$_] })
    $differences += @($rightHashes.Keys | Where-Object { !$leftHashes.ContainsKey($_) })
    Assert-True (!$differences.Count) "Different files between $Left and $Right ($($differences.Count)): $($differences | Select-Object -First 15)"
}

function Get-Page([string] $Path, [int] $Status = 200, [string] $Mime, [string] $Location) {
    $response = $client.GetAsync([uri]::new($baseUri, $Path)).GetAwaiter().GetResult()
    try {
        Assert-True ([int]$response.StatusCode -eq $Status) "$Path returned $([int]$response.StatusCode), expected $Status."
        $actualLocation = if ($response.Headers.Location) { $response.Headers.Location.OriginalString }
        if ($Location) {
            Assert-True ($actualLocation -ceq $Location) "$Path redirected to '$actualLocation', expected '$Location'."
        } else {
            Assert-True (!$actualLocation) "$Path unexpectedly redirected to '$actualLocation'."
        }
        if ($Mime) {
            Assert-True ($response.Content.Headers.ContentType.MediaType -match $Mime) "$Path has unexpected content type."
        }
        if ($Path -notmatch '/public/') {
            Assert-True ($response.Headers.CacheControl.NoStore -and !$response.Headers.ETag) "$Path has unexpected cache headers."
        }
        $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        $response.Dispose()
    }
}

function Get-Xrefs([string] $Yaml, [string] $Api) {
    $xref = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $uid = $null
    # The native DocFX xref writer emits simple scalar UIDs and hrefs for this fixture.
    foreach ($line in ($Yaml -split '\r?\n')) {
        if ($line -cmatch '^- uid: (.+)$') { $uid = $Matches[1] }
        if ($uid -and $line -cmatch '^  href: (.+)$') {
            $href = $Matches[1]
            if (("/$href").StartsWith($Api, [StringComparison]::Ordinal)) { $xref.Add($uid, $href) }
            $uid = $null
        }
    }
    $xref
}

$manifest = Read-Json "$site/framework-views.json"
Assert-True ($manifest.apiPath -ceq '/api/') "Unexpected API root '$($manifest.apiPath)'; expected '/api/'."
Assert-True (($manifest.viewOrder -join ',') -ceq 'net-11.0,net-10.0,netstandard-2.1,netstandard-2.0') 'Unexpected framework views or order.'
Assert-True (($manifest.availability.sets[$manifest.availability.pages['aspnet/Cuemon.AspNetCore.html']] -join ',') -ceq 'net-11.0,net-10.0') 'Unexpected availability for aspnet/Cuemon.AspNetCore.html.'
Assert-True (($manifest.availability.sets[$manifest.availability.pages['dotnet/Cuemon.html']] -join ',') -ceq 'net-11.0,net-10.0,netstandard-2.0') 'Unexpected availability for dotnet/Cuemon.html.'
Assert-True (($manifest.availability.sets[$manifest.availability.pages["dotnet/$legacy.html"]] -join ',') -ceq 'netstandard-2.0') "Unexpected availability for dotnet/$legacy.html."
Assert-True (($manifest.availability.sets[$manifest.availability.pages["dotnet/$buffer.html"]] -join ',') -ceq 'net-11.0,net-10.0,netstandard-2.1') "Unexpected availability for dotnet/$buffer.html."
if ($CompareWorkspace) {
    Compare-Trees $site "$CompareWorkspace/site"
    foreach ($entry in $manifest.views.Values) {
        $directory = $entry.directory
        Compare-Trees "$workspace/$directory$($manifest.apiPath)" "$CompareWorkspace/$directory$($manifest.apiPath)"
    }
    Write-Host 'Isolated metadata and packaged site match the comparison build.'
}

$container = $null
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(10)
try {
    if (!$Origin) {
        $mounts = @('--mount', "type=bind,source=$site,target=/usr/share/nginx/html,readonly",
            '--mount', "type=bind,source=$workspace/nginx.conf,target=/etc/nginx/conf.d/default.conf,readonly")
        $container = & docker run --rm -d -p 127.0.0.1::8080 @mounts $NginxImage
        Assert-True ($LASTEXITCODE -eq 0) 'Could not start isolated NGINX.'
        $port = (& docker port $container 8080/tcp).Trim()
        Assert-True ($LASTEXITCODE -eq 0 -and $port -match '^127\.0\.0\.1:\d+$') 'Could not resolve mapped NGINX port.'
        $Origin = "http://$port"
    }
    $baseUri = [uri]$Origin
    Write-Host "Testing $Origin"
    for ($i = 0; $i -lt 20; $i++) {
        try { Get-Page '/framework-views.json' 200 'application/json' | Out-Null; break }
        catch {
            if ($i -eq 19) { throw }
            Start-Sleep -Milliseconds 250
        }
    }

    $api = $manifest.apiPath
    $dotnetApi = '/api/dotnet/'
    $aspnetApi = '/api/aspnet/'
    $factoryPath = "$dotnetApi$factory.html"
    $aspnetPath = "$aspnetApi$aspnetNamespace.html"
    $defaultHtml = Get-Page $factoryPath 200 'text/html'
    Assert-True ($defaultHtml -ceq (Get-Page "$($factoryPath)?view=$($manifest.defaultView)" 200 'text/html')) 'Implicit and explicit default differ.'
    Get-Page "$($factoryPath)?view=unknown" 400 | Out-Null
    Get-Page "$($factoryPath)?view=$($manifest.defaultView.ToUpperInvariant())" 400 | Out-Null
    Get-Page "$($aspnetPath)?view=unknown" 400 | Out-Null
    Get-Page '/index.html?view=unknown' 200 'text/html' | Out-Null
    Get-Page '/public/docfx.min.css?view=unknown' 200 'text/css' | Out-Null
    Get-Page '/public/docfx.min.js' 200 'javascript' | Out-Null
    Get-Page '/images/favicon.ico' 200 'image/' | Out-Null
    $font = Get-ChildItem "$site/public" -Filter '*.woff2' | Select-Object -First 1
    $fontResponse = $client.GetAsync([uri]::new($baseUri, "/public/$($font.Name)")).GetAwaiter().GetResult()
    try {
        Assert-True ($fontResponse.IsSuccessStatusCode -and $fontResponse.Headers.CacheControl.ToString().Contains('immutable')) 'Fingerprinted font caching policy changed.'
    } finally { $fontResponse.Dispose() }

    # Reported Cuemon navigation scenario and destination-aware server-side fallback checks
    Get-Page '/api/dotnet/Cuemon.html?view=netstandard-2.0' 200 'text/html' | Out-Null
    Get-Page "$($aspnetPath)?view=netstandard-2.0" 302 $null "$($aspnetPath)?view=net-11.0" | Out-Null
    Get-Page "$($aspnetPath)?view=netstandard-2.1" 302 $null "$($aspnetPath)?view=net-11.0" | Out-Null
    Get-Page "$($aspnetPath)?tag=a&view=netstandard-2.0&tag=b" 302 $null "$($aspnetPath)?tag=a&tag=b&view=net-11.0" | Out-Null
    $aspnetDefault = Get-Page "$($aspnetPath)?view=net-11.0" 200 'text/html'
    Assert-True ($aspnetDefault.Contains('Cuemon.AspNetCore')) 'Resolved Cuemon.AspNetCore page missing expected content.'
    Get-Page "$($aspnetPath)?view=net-10.0" 200 'text/html' | Out-Null
    $notFound = Get-Page '/api/aspnet/DoesNotExist.html?view=netstandard-2.0' 404 'text/html'
    Assert-True ($notFound.Contains('<h1>Not Found</h1>') -and $notFound.Contains('data-api-path="/api/"')) 'The document 404 did not render the Cuemon error page.'
    Assert-True ($notFound.Contains('Cuemon for .NET') -and $notFound.Contains('images/50x50.png') -and $notFound.Contains('Copyright 2008-2026 Geekle')) 'The document 404 lost the configured Cuemon branding.'
    Get-Page '/api/aspnet/toc.json?view=netstandard-2.0' 404 'text/plain' | Out-Null
    Get-Page "$dotnetApi$legacy.html" 302 $null "$dotnetApi$legacy.html?view=netstandard-2.0" | Out-Null
    Get-Page "$dotnetApi$legacy.html?view=net-11.0" 302 $null "$dotnetApi$legacy.html?view=netstandard-2.0" | Out-Null
    Get-Page "$dotnetApi$buffer.html?view=netstandard-2.0" 302 $null "$dotnetApi$buffer.html?view=net-11.0" | Out-Null
    Get-Page "${dotnetApi}Cuemon.Validator.html?view=netstandard-2.1" 302 $null "${dotnetApi}Cuemon.Validator.html?view=net-11.0" | Out-Null

    $rootToc = Get-Page '/toc.json' 200 'application/json'
    Assert-True ($rootToc.Contains('api/dotnet/Cuemon.html') -and $rootToc.Contains('api/aspnet/Cuemon.AspNetCore.html')) 'Root navigation TOC missing expected Cuemon API entries.'

    foreach ($view in $manifest.views.Keys) {
        $entry = $manifest.views[$view]
        $stage = "$workspace/$($entry.directory)"
        $dotnetInventory = Read-Json "$stage${dotnetApi}.manifest"
        Assert-True ($dotnetInventory.Count -eq $dotnetBaselineUids[$entry.tfm]) "Unexpected api/dotnet baseline UID count for $view."
        $hasAspNet = $entry.tfm -cin 'net11.0', 'net10.0'
        $aspnetManifestPath = "$stage${aspnetApi}.manifest"
        Assert-True ((Test-Path -LiteralPath $aspnetManifestPath -PathType Leaf) -eq $hasAspNet) "Unexpected api/aspnet manifest presence for $view."
        $combinedUids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $combinedUids.UnionWith([string[]]@($dotnetInventory.Keys))
        $aspnetCount = 0
        if ($hasAspNet) {
            $aspnetInventory = Read-Json $aspnetManifestPath
            Assert-True ($aspnetInventory.Count -eq $aspnetBaselineUids[$entry.tfm]) "Unexpected api/aspnet baseline UID count for $view ($($aspnetInventory.Count))."
            $aspnetCount = $aspnetInventory.Count
            $combinedUids.UnionWith([string[]]@($aspnetInventory.Keys))
        }
        $xref = Get-Xrefs (Get-Page $entry.xref) $api
        $renderedUids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $renderedUids.UnionWith([string[]]@($xref.Keys | Where-Object { !$_.EndsWith('*') }))
        Assert-True ($renderedUids.SetEquals($combinedUids)) "$view served xrefs differ from the isolated DocFX inventory."
        $pages = @{}
        foreach ($uid in $xref.Keys) {
            $path, $anchor = $xref[$uid].Split('#', 2)
            if (!$pages.ContainsKey($path)) { $pages[$path] = Get-Page "/$($path)?view=$view" 200 'text/html' }
            if ($anchor) {
                $id = [Net.WebUtility]::HtmlEncode([uri]::UnescapeDataString($anchor))
                Assert-True ($pages[$path].Contains("id=""$id""")) "Missing anchor for $uid in $view."
            }
        }
        $example = $pages.GetEnumerator() | Where-Object Value -Match 'href="[^"]*run-actions/[^"]+\.ps1"' | Select-Object -First 1
        Assert-True ($null -ne $example) "No run-action link in $view."
        $href = [regex]::Match($example.Value, 'href="([^"]*run-actions/[^"]+\.ps1)"').Groups[1].Value
        $publicPage = [uri]::new($baseUri, "/$($example.Key)?view=$view")
        $runAction = [uri]::new($publicPage, $href)
        Assert-True ($runAction.AbsolutePath.StartsWith('/run-actions/')) "Run-action escaped the shared public path in $view."
        Get-Page $runAction.AbsolutePath | Out-Null

        $isLegacy = $entry.tfm -ceq 'netstandard2.0'
        $toc = Get-Page "$($dotnetApi)toc.json?view=$view" 200 'application/json'
        if ($hasAspNet) {
            $aspnetToc = Get-Page "$($aspnetApi)toc.json?view=$view" 200 'application/json'
            Assert-True ($aspnetToc.Contains("""topicUid"":""$aspnetNamespace""")) "Missing $aspnetNamespace in api/aspnet TOC for $view."
        } else {
            Get-Page "$($aspnetApi)toc.json?view=$view" 404 | Out-Null
        }
        $index = Get-Page "/_framework-search/$($entry.directory)/index.json" 200 'application/json' | ConvertFrom-Json -AsHashtable
        foreach ($path in $index.Keys) {
            if (("/$path").StartsWith($api) -and !$pages.ContainsKey($path)) { throw "Search indexes unavailable page $path in $view." }
        }
        Assert-True ($xref.ContainsKey($aspnetNamespace) -eq $hasAspNet) "Wrong xref availability for $aspnetNamespace in $view."
        Assert-True ($index.Contains("api/aspnet/$aspnetNamespace.html") -eq $hasAspNet) "Wrong search availability for $aspnetNamespace in $view."
        $overloads = @($xref.Keys | Where-Object { $_.StartsWith("$factory.Create") -and $_.Contains('System.Buffers.IBufferWriter{System.Byte}') })
        $expectedCount = if ($isLegacy) { 0 } else { 6 }
        Assert-True ($overloads.Count -eq $expectedCount) "Wrong buffer writer overload count in $view."
        $create = $pages[$xref["$factory.Create*"]]
        Assert-True ([regex]::Matches($create, 'id="[^"]+_System_Buffers_IBufferWriter_System_Byte_[^"]*"').Count -eq $expectedCount) "Wrong served overload anchors in $view."
        Assert-True ($create.Contains('href="Cuemon.IO.BufferWriterOptions.html"') -eq !$isLegacy) "Wrong BufferWriterOptions cross-reference in $view."
        $exception = 'Cuemon.ArgumentReservedKeywordException'
        if ($xref.ContainsKey($exception)) {
            $inheritsSerialization = $pages[$xref[$exception]].Contains('system.argumentoutofrangeexception.getobjectdata')
            Assert-True ($inheritsSerialization -eq $isLegacy) "Wrong inherited serialization member in $view."
        }
        if ($isLegacy) {
            $legacyNamespace = $pages[$xref['System.Runtime.CompilerServices']]
            Assert-True ($legacyNamespace.Contains('provides polyfill types')) 'Missing compatibility namespace overwrite.'
        }

        foreach ($type in $legacy, $buffer, 'Cuemon.Validator') {
            $expected = switch ($type) {
                $legacy { $isLegacy }
                $buffer { !$isLegacy }
                default { $entry.tfm -cne 'netstandard2.1' }
            }
            $expectedFallback = switch ($type) {
                $legacy { 'netstandard-2.0' }
                default { 'net-11.0' }
            }
            $path = "$($dotnetApi.TrimStart('/'))$type.html"
            Assert-True ($xref.ContainsKey($type) -eq $expected) "Wrong xref availability for $type in $view."
            Assert-True ($toc.Contains("""topicUid"":""$type""") -eq $expected) "Wrong TOC availability for $type in $view."
            Assert-True ($index.Contains($path) -eq $expected) "Wrong search availability for $type in $view."
            if (!$expected) {
                Get-Page "/$($path)?view=$view" 302 $null "/$($path)?view=$expectedFallback" | Out-Null
                continue
            }
            Assert-True ($pages[$path] -match 'github\.com/codebeltnet/cuemon/blob/[^"]+\.cs/#L\d+') "Missing source link for $type in $view."
        }
        foreach ($file in Get-ChildItem "$stage/api/types" -Filter '*.md') {
            if (!$xref.ContainsKey($file.BaseName)) { continue }
            if ((Get-Content -LiteralPath $file.FullName -Raw) -notmatch '(?m)^example:') { continue }
            $html = $pages[$xref[$file.BaseName]]
            Assert-True ($html -match '(?s)<h2 id="[^"]+_examples">Examples</h2>.*?<pre><code[^>]*>\s*\S') "Missing authored example for $($file.BaseName) in $view."
        }
        Get-Page "/_frameworks/$($entry.directory)$factoryPath" 404 | Out-Null
        Write-Host "$view passed $($combinedUids.Count) UID ($($dotnetInventory.Count) dotnet + $aspnetCount aspnet), anchor, TOC, search and fallback checks across $($pages.Count) served API pages."
    }
} finally {
    $client.Dispose()
    if ($container) { & docker stop $container | Out-Null }
}
