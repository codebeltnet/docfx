#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('ValidateTag', 'Assemble', 'Split', 'VerifyDraftAssets', 'Resolve', 'Restore', 'Publish')]
    [string] $Command,
    [string] $InputsDir = 'inputs',
    [string] $OutDir = 'out',
    [string] $AssetsDir = 'assets',
    [string] $ResolvedDir = 'resolved',
    [string] $ReleaseDir = 'release',
    [long] $PartSizeBytes = 1073741824
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Import-Module (Join-Path $PSScriptRoot 'DocfxImage.psm1')

function Invoke-GitHubApi {
    param([Parameter(Mandatory)][string] $Endpoint)

    $raw = & gh api $Endpoint 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = (@($raw) | ForEach-Object { $_.ToString() }) -join "`n"
        throw "gh api $Endpoint exited with code $LASTEXITCODE`: $text"
    }
    ((@($raw) | ForEach-Object { $_.ToString() }) -join "`n") | ConvertFrom-Json -AsHashtable
}

function Invoke-ReleaseAssetDownload {
    param(
        [Parameter(Mandatory)][hashtable] $Asset,
        [Parameter(Mandatory)][string] $Destination
    )

    if (-not $Asset['digest'] -or $Asset['digest'] -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "Release asset '$($Asset['name'])' has no authoritative SHA-256 digest."
    }
    if (-not $Asset['browser_download_url']) {
        throw "Release asset '$($Asset['name'])' has no download URL."
    }

    Invoke-WebRequest -Uri $Asset['browser_download_url'] -OutFile $Destination
    $actualHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualSize = (Get-Item -LiteralPath $Destination).Length
    if ("sha256:$actualHash" -cne $Asset['digest'] -or $actualSize -ne [long]$Asset['size']) {
        throw "Release asset '$($Asset['name'])' checksum or size mismatch."
    }
}

function Assert-TagPlanMatchesAuthoritativeScript {
    param([Parameter(Mandatory)][hashtable] $Meta)

    $plan = & (Join-Path $repoRoot 'BuildAndPushDocfxImage.ps1') `
        -DocfxVersion $Meta['DocfxVersion'] `
        -EngineVersion $Meta['EngineVersion'] `
        -ContainerRegistry 'codebeltnet/' `
        -Tag 'docfx' `
        -BuildOnly `
        -Platform 'linux/amd64' `
        -WhatIf `
        -PassThru

    foreach ($key in @('Tags', 'ConvenienceTags', 'EngineQualifiedTags')) {
        $expected = @($plan.$key)
        $actual = @($Meta[$key])
        if (($expected -join ',') -cne ($actual -join ',')) {
            throw "Saved release metadata '$key' differs from authoritative BuildAndPushDocfxImage tag contract."
        }
    }
}

function Write-ReleaseSummary {
    param([Parameter(Mandatory)][hashtable] $Meta)

    if (-not $env:GITHUB_STEP_SUMMARY) { return }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("### DocFX Release $($Meta['ReleaseTag'])")
    $lines.Add('')
    $lines.Add("- DocFX CLI: $($Meta['DocfxVersion'])")
    $lines.Add("- Codebelt engine: $($Meta['EngineVersion'])")
    $lines.Add("- Source revision: $($Meta['SourceCommit'])")
    $lines.Add("- Verified OCI index: ``$($Meta['OciIndexDigest'])``")
    $lines.Add("- Engine-qualified tags: $(@($Meta['EngineQualifiedTags']) -join ', ')")
    $lines.Add("- Convenience tags: $(@($Meta['ConvenienceTags']) -join ', ')")
    foreach ($record in @($Meta['Verification'])) {
        $lines.Add("- $($record['Platform']): native validation passed; image size $($record['SizeBytes']) bytes; OCI archive $($record['OciArchiveBytes']) bytes")
    }
    $lines.Add('')
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($lines -join "`n") -Encoding utf8NoBOM
}

function Assert-CurrentLatestRelease {
    $identityPath = Join-Path $ResolvedDir 'identity.json'
    if (!(Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw "Resolved release identity file is missing at '$identityPath'."
    }
    $resolved = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -AsHashtable
    $repo = $env:GITHUB_REPOSITORY
    $latest = Invoke-GitHubApi -Endpoint "repos/$repo/releases/latest"
    if ($latest['id'] -ne $resolved['releaseId'] -or $latest['tag_name'] -cne $resolved['tag'] -or $latest['draft'] -or $latest['prerelease']) {
        throw "Latest published release changed after verification (resolved $($resolved['tag']), latest $($latest['tag_name'])); refusing stale convenience tag promotion."
    }
    $resolved
}

function Invoke-ValidateTag {
    $tag = $env:GITHUB_REF_NAME
    $engineVersion = Resolve-ReleaseTagVersion -Tag $tag
    $docfxVersion = Test-DocfxVersionConsistency -RootPath $repoRoot
    $headSha = Get-DocfxSourceRevision -Required -RootPath $repoRoot
    if ($env:GITHUB_SHA -and $headSha -cne $env:GITHUB_SHA) {
        throw "Checked-out revision '$headSha' does not match GITHUB_SHA '$($env:GITHUB_SHA)'."
    }

    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "engine-version=$engineVersion" -Encoding utf8NoBOM
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "docfx-version=$docfxVersion" -Encoding utf8NoBOM
    }

    Write-Output "Validated release tag $tag (engine $engineVersion, DocFX CLI $docfxVersion, revision $headSha)."
}

function Invoke-Assemble {
    $expectedTag = $env:GITHUB_REF_NAME
    $expectedEngineVersion = Resolve-ReleaseTagVersion -Tag $expectedTag
    $expectedSha = $env:GITHUB_SHA
    $expectedDocfxVersion = Test-DocfxVersionConsistency -RootPath $repoRoot

    $metaFiles = @(Get-ChildItem -LiteralPath $InputsDir -Filter 'docfx-image.json' -Recurse -File | Sort-Object FullName)
    if ($metaFiles.Count -ne 2) {
        throw "Both native verification records (amd64 and arm64) are required; found $($metaFiles.Count)."
    }

    $records = @(foreach ($file in $metaFiles) {
        Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    })

    $first = $records[0]
    foreach ($record in $records) {
        if ($record['NativeVerified'] -ne $true) {
            throw "Native verification record for '$($record['Platform'])' is not verified."
        }
        foreach ($key in @('DocfxVersion', 'EngineVersion', 'SourceCommit', 'SourceRepository')) {
            if ($record[$key] -cne $first[$key]) {
                throw "Native verification identity mismatch on '$key'."
            }
        }
        foreach ($listKey in @('Tags', 'ConvenienceTags', 'EngineQualifiedTags')) {
            if ((@($record[$listKey]) -join ',') -cne (@($first[$listKey]) -join ',')) {
                throw "Native verification tag mismatch on '$listKey'."
            }
        }
    }

    $platforms = @($records | ForEach-Object { $_['Platform'] } | Sort-Object)
    if (($platforms -join ',') -cne 'linux/amd64,linux/arm64') {
        throw "Both native CPUs (linux/amd64 and linux/arm64) are required; found '$($platforms -join ',')'."
    }
    if ($first['SourceCommit'] -cne $expectedSha -or $first['EngineVersion'] -cne $expectedEngineVersion -or $first['DocfxVersion'] -cne $expectedDocfxVersion) {
        throw 'Release source, engine version, or DocFX CLI version does not match native verification records.'
    }

    Assert-TagPlanMatchesAuthoritativeScript -Meta $first

    $archiveFiles = @(Get-ChildItem -LiteralPath $InputsDir -Filter '*.oci.tar' -Recurse -File | Sort-Object FullName)
    if ($archiveFiles.Count -ne 2) {
        throw "Exactly two native OCI archives are required; found $($archiveFiles.Count)."
    }

    $verifiedInputs = [System.Collections.Generic.List[string]]::new()
    foreach ($archiveFile in $archiveFiles) {
        $parentMetaFile = Join-Path $archiveFile.DirectoryName 'docfx-image.json'
        $record = Get-Content -LiteralPath $parentMetaFile -Raw | ConvertFrom-Json -AsHashtable
        $cpu = $record['Architecture']
        $verified = Invoke-OciArtifact -Arguments @(
            'verify', $archiveFile.FullName
            '--version', $expectedEngineVersion
            '--docfx-version', $expectedDocfxVersion
            '--revision', $expectedSha
            '--source', $first['SourceRepository']
            '--platform', $cpu
            '--check-seal'
            '--no-seal'
        ) -RootPath $repoRoot | ConvertFrom-Json
        if ($verified.configs.$cpu -cne $record['ConfigDigest']) {
            throw "Native test record for '$cpu' does not match the assembled OCI image config digest."
        }
        if ($verified.archiveSha256 -cne $record['ArchiveSha256']) {
            throw "Native test record for '$cpu' does not match the OCI archive SHA-256."
        }
        if ($archiveFile.Length -ne $record['OciArchiveBytes']) {
            throw "Native test record for '$cpu' does not match the OCI archive size."
        }
        $verifiedInputs.Add($archiveFile.FullName)
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $combinedArchive = Join-Path (Resolve-Path -LiteralPath $OutDir).Path 'docfx.oci.tar'
    $mergeArgs = @(
        'merge', $combinedArchive
        '--version', $expectedEngineVersion
        '--docfx-version', $expectedDocfxVersion
        '--revision', $expectedSha
        '--source', $first['SourceRepository']
    )
    foreach ($inputPath in $verifiedInputs) {
        $mergeArgs += @('--input', $inputPath)
    }
    $merged = Invoke-OciArtifact -Arguments $mergeArgs -RootPath $repoRoot | ConvertFrom-Json

    $releaseMeta = [ordered]@{
        ReleaseTag          = $expectedTag
        DocfxVersion        = $expectedDocfxVersion
        EngineVersion       = $expectedEngineVersion
        SourceCommit        = $expectedSha
        SourceRepository    = $first['SourceRepository']
        Repository          = $first['Repository']
        Tags                = @($first['Tags'])
        ConvenienceTags     = @($first['ConvenienceTags'])
        EngineQualifiedTags = @($first['EngineQualifiedTags'])
        OciIndexDigest      = $merged.indexDigest
        ArchiveSha256       = $merged.archiveSha256
        ArchiveBytes        = $merged.archiveBytes
        ReleaseRunId        = $env:GITHUB_RUN_ID
        ReleaseRunAttempt   = $env:GITHUB_RUN_ATTEMPT
        Verification        = $records
    }
    $releaseMeta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutDir 'release.json') -Encoding utf8NoBOM
    Write-ReleaseSummary -Meta $releaseMeta

    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "digest=$($merged.indexDigest)" -Encoding utf8NoBOM
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "version=$expectedEngineVersion" -Encoding utf8NoBOM
    }
    Write-Output "Assembled multi-platform OCI index $($merged.indexDigest)."
}

function Invoke-Split {
    $archivePath = Join-Path $OutDir 'docfx.oci.tar'
    $releaseJsonPath = Join-Path $OutDir 'release.json'
    if (!(Test-Path -LiteralPath $archivePath -PathType Leaf) -or !(Test-Path -LiteralPath $releaseJsonPath -PathType Leaf)) {
        throw "Expected assembled archive and release.json in '$OutDir'."
    }

    New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null
    $splitResult = Invoke-OciArtifact -Arguments @(
        'split', $archivePath
        '--output-dir', $AssetsDir
        '--prefix', 'docfx'
        '--part-size', "$PartSizeBytes"
        '--write-checksum'
    ) -RootPath $repoRoot | ConvertFrom-Json

    $meta = Get-Content -LiteralPath $releaseJsonPath -Raw | ConvertFrom-Json -AsHashtable
    $meta['ArchiveSha256'] = $splitResult.archiveSha256
    $meta['ArchiveBytes'] = $splitResult.archiveBytes
    $meta['Pieces'] = @(foreach ($piece in $splitResult.pieces) {
        [ordered]@{
            Name   = $piece.name
            Sha256 = $piece.sha256
            Size   = $piece.size
        }
    })
    $meta | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $AssetsDir 'docfx-release.json') -Encoding utf8NoBOM
    Write-Output "Prepared $($meta['Pieces'].Count) release asset piece(s) in '$AssetsDir'."
}

function Invoke-VerifyDraftAssets {
    $repo = $env:GITHUB_REPOSITORY
    $tag = $env:RELEASE_TAG
    $null = Resolve-ReleaseTagVersion -Tag $tag

    $localFiles = @(Get-ChildItem -LiteralPath $ReleaseDir -File | Sort-Object Name)
    if ($localFiles.Count -eq 0) {
        throw "No release asset files found in '$ReleaseDir'."
    }

    $releases = @(Invoke-GitHubApi -Endpoint "repos/$repo/releases?per_page=30")
    $draft = @($releases | Where-Object { $_['tag_name'] -ceq $tag -and $_['draft'] -eq $true })
    if ($draft.Count -ne 1) {
        throw "Expected exactly one draft GitHub release for tag '$tag'; found $($draft.Count)."
    }

    $attached = @{}
    foreach ($asset in @($draft[0]['assets'])) {
        $attached[$asset['name']] = $asset
    }

    foreach ($file in $localFiles) {
        if (-not $attached.ContainsKey($file.Name)) {
            throw "Draft release '$tag' is missing expected asset '$($file.Name)'."
        }
        $remote = $attached[$file.Name]
        if ([long]$remote['size'] -ne $file.Length) {
            throw "Draft release asset '$($file.Name)' size mismatch: expected $($file.Length), found $($remote['size'])."
        }
        if ($remote['digest']) {
            $localDigest = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($remote['digest'] -cne $localDigest) {
                throw "Draft release asset '$($file.Name)' digest mismatch: expected $localDigest, found $($remote['digest'])."
            }
        }
    }

    Write-Output "Verified $($localFiles.Count) durable asset(s) attached to draft release $tag."
}

function Invoke-Resolve {
    $repo = $env:GITHUB_REPOSITORY
    if ($repo -cne 'codebeltnet/docfx') {
        throw "Production deployment is restricted to 'codebeltnet/docfx'; got '$repo'."
    }

    $tag = $env:RELEASE_TAG
    $engineVersion = Resolve-ReleaseTagVersion -Tag $tag
    $eventName = $env:GITHUB_EVENT_NAME

    $eventData = $null
    if ($eventName -ceq 'workflow_dispatch') {
        if ($env:GITHUB_REF -cne 'refs/heads/main') {
            throw "Deployment recovery must be dispatched from 'refs/heads/main'; got '$($env:GITHUB_REF)'."
        }
    } else {
        $eventData = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable
        if ($eventName -cne 'release' -or $eventData['action'] -cne 'published' -or $eventData['release']['tag_name'] -cne $tag) {
            throw 'Unexpected release event payload for production deployment.'
        }
    }

    $release = Invoke-GitHubApi -Endpoint "repos/$repo/releases/tags/$tag"
    $latest = Invoke-GitHubApi -Endpoint "repos/$repo/releases/latest"
    if ($release['draft'] -or $release['prerelease'] -or -not $release['published_at'] -or $latest['id'] -ne $release['id']) {
        throw "Requested release '$tag' must be the latest published stable release. Refusing to deploy drafts, prereleases, or superseded releases."
    }
    if ($eventName -ceq 'release' -and $eventData['release']['id'] -ne $release['id']) {
        throw 'Published release ID changed during resolution.'
    }

    $commit = (Invoke-GitHubApi -Endpoint "repos/$repo/commits/$tag")['sha']
    if ($commit -cnotmatch '^[0-9a-f]{40}$') {
        throw "Unable to resolve commit SHA for release tag '$tag'."
    }
    $comparison = Invoke-GitHubApi -Endpoint "repos/$repo/compare/$commit...main"
    if ($comparison['status'] -cnotin @('ahead', 'identical')) {
        throw "Release source commit '$commit' is not in main branch history (status '$($comparison['status'])')."
    }

    $assets = @{}
    foreach ($asset in @($release['assets'])) {
        $assets[$asset['name']] = $asset
    }
    foreach ($requiredAsset in @('docfx-release.json', 'docfx.oci.tar.sha256')) {
        if (-not $assets.ContainsKey($requiredAsset)) {
            throw "Published release '$tag' is missing required durable asset '$requiredAsset'."
        }
    }

    New-Item -ItemType Directory -Path $ResolvedDir -Force | Out-Null
    $identity = [ordered]@{
        tag           = $tag
        engineVersion = $engineVersion
        releaseId     = $release['id']
        sha           = $commit
        assets        = $assets
    }
    $identity | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ResolvedDir 'identity.json') -Encoding utf8NoBOM

    if ($env:GITHUB_OUTPUT) {
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "sha=$commit" -Encoding utf8NoBOM
        Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "engine-version=$engineVersion" -Encoding utf8NoBOM
    }
    Write-Output "Resolved latest published release $tag at $commit."
}

function Invoke-Restore {
    $identityPath = Join-Path $ResolvedDir 'identity.json'
    if (!(Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw "Resolved release identity file is missing at '$identityPath'."
    }
    $resolved = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json -AsHashtable
    $assets = $resolved['assets']

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $releaseJsonPath = Join-Path $OutDir 'release.json'
    $checksumAssetPath = Join-Path $OutDir 'docfx.oci.tar.sha256.asset'
    Invoke-ReleaseAssetDownload -Asset $assets['docfx-release.json'] -Destination $releaseJsonPath
    Invoke-ReleaseAssetDownload -Asset $assets['docfx.oci.tar.sha256'] -Destination $checksumAssetPath

    $meta = Get-Content -LiteralPath $releaseJsonPath -Raw | ConvertFrom-Json -AsHashtable
    if ($meta['ReleaseTag'] -cne $resolved['tag'] -or
        $meta['EngineVersion'] -cne $resolved['engineVersion'] -or
        $meta['SourceCommit'] -cne $resolved['sha']) {
        throw 'Release metadata does not match the resolved published release identity.'
    }

    $repo = $env:GITHUB_REPOSITORY
    $run = Invoke-GitHubApi -Endpoint "repos/$repo/actions/runs/$($meta['ReleaseRunId'])/attempts/$($meta['ReleaseRunAttempt'])"
    if ($run['event'] -cne 'push' -or
        $run['path'] -cne '.github/workflows/release.yml' -or
        $run['head_sha'] -cne $resolved['sha'] -or
        $run['head_branch'] -cne $resolved['tag'] -or
        [int]$run['run_attempt'] -ne [int]$meta['ReleaseRunAttempt'] -or
        $run['conclusion'] -cne 'success') {
        throw 'Authoritative tag release workflow run did not succeed for this release and commit.'
    }

    $records = @($meta['Verification'])
    $recordPlatforms = @($records | ForEach-Object { $_['Platform'] } | Sort-Object)
    if ($records.Count -ne 2 -or ($recordPlatforms -join ',') -cne 'linux/amd64,linux/arm64') {
        throw 'Both native architecture verification records (linux/amd64 and linux/arm64) are required.'
    }
    foreach ($record in $records) {
        if ($record['NativeVerified'] -ne $true -or
            $record['DocfxVersion'] -cne $meta['DocfxVersion'] -or
            $record['EngineVersion'] -cne $meta['EngineVersion'] -or
            $record['SourceCommit'] -cne $meta['SourceCommit'] -or
            (@($record['Tags']) -join ',') -cne (@($meta['Tags']) -join ',') -or
            (@($record['ConvenienceTags']) -join ',') -cne (@($meta['ConvenienceTags']) -join ',') -or
            (@($record['EngineQualifiedTags']) -join ',') -cne (@($meta['EngineQualifiedTags']) -join ',')) {
            throw 'Native verification record identity mismatch.'
        }
    }

    Assert-TagPlanMatchesAuthoritativeScript -Meta $meta

    $piecesDir = Join-Path $OutDir 'pieces'
    New-Item -ItemType Directory -Path $piecesDir -Force | Out-Null
    try {
        foreach ($piece in @($meta['Pieces'])) {
            $pieceName = $piece['Name']
            if ($pieceName -cnotmatch '^docfx\.oci\.part\d{3}$') {
                throw "Invalid release archive piece name '$pieceName'."
            }
            if (-not $assets.ContainsKey($pieceName)) {
                throw "Published release is missing archive piece '$pieceName'."
            }
            $piecePath = Join-Path $piecesDir $pieceName
            Invoke-ReleaseAssetDownload -Asset $assets[$pieceName] -Destination $piecePath
        }

        $archivePath = Join-Path (Resolve-Path -LiteralPath $OutDir).Path 'docfx.oci.tar'
        $null = Invoke-OciArtifact -Arguments @(
            'reassemble'
            '--manifest', $releaseJsonPath
            '--input-dir', $piecesDir
            '--output', $archivePath
            '--checksum', $checksumAssetPath
        ) -RootPath $repoRoot

        $null = Invoke-OciArtifact -Arguments @(
            'verify', $archivePath
            '--version', $meta['EngineVersion']
            '--docfx-version', $meta['DocfxVersion']
            '--revision', $meta['SourceCommit']
            '--source', $meta['SourceRepository']
            '--expected-digest', $meta['OciIndexDigest']
            '--check-seal'
            '--no-seal'
        ) -RootPath $repoRoot
    } finally {
        if (Test-Path -LiteralPath $piecesDir) {
            Remove-Item -LiteralPath $piecesDir -Recurse -Force
        }
        if (Test-Path -LiteralPath $checksumAssetPath) {
            Remove-Item -LiteralPath $checksumAssetPath -Force
        }
    }

    Write-ReleaseSummary -Meta $meta
    $meta
}

function Invoke-Publish {
    $null = Assert-CurrentLatestRelease
    $meta = Invoke-Restore
    $archivePath = Join-Path (Resolve-Path -LiteralPath $OutDir).Path 'docfx.oci.tar'

    $result = Publish-DocfxOciArchive `
        -ArchivePath $archivePath `
        -EngineVersion $meta['EngineVersion'] `
        -DocfxVersion $meta['DocfxVersion'] `
        -Revision $meta['SourceCommit'] `
        -SourceRepository $meta['SourceRepository'] `
        -Tags @($meta['Tags']) `
        -EngineQualifiedTags @($meta['EngineQualifiedTags']) `
        -ExpectedIndexDigest $meta['OciIndexDigest'] `
        -BeforeConvenience { $null = Assert-CurrentLatestRelease }

    Write-Output "Promoted $($result.Published.Count) tags to $($result.Repository)@$($result.IndexDigest)."
}

switch ($Command) {
    'ValidateTag'       { Invoke-ValidateTag }
    'Assemble'          { Invoke-Assemble }
    'Split'             { Invoke-Split }
    'VerifyDraftAssets' { Invoke-VerifyDraftAssets }
    'Resolve'           { Invoke-Resolve }
    'Restore'           { $null = Invoke-Restore }
    'Publish'           { Invoke-Publish }
}
