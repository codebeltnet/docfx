#requires -Version 7.0
Set-StrictMode -Version Latest

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$script:SemVerPattern = '^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-(?<prerelease>(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
$script:ReleaseTagPattern = '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$'
$script:DockerTagPattern = '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
$script:EngineSuffixPattern = '-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$'
$script:RepositoryPattern = '^(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?/)?[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*)*$'
$script:SkopeoUtilityImage = 'quay.io/skopeo/stable:v1.20.0'
$script:CanonicalSourceRepository = 'https://github.com/codebeltnet/docfx'
$script:RequiredPlatforms = @('linux/arm64', 'linux/amd64')

function Resolve-SemVer {
    param(
        [string] $Value,
        [Parameter(Mandatory)][string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must not be empty. Specify a Semantic Version such as '1.1.0'."
    }
    if ($Value.Contains('+')) {
        throw "Invalid $Name '$Value'. Semantic Versioning build metadata ('+...') is not valid in Docker image tags."
    }
    if ($Value -cmatch '^v\d') {
        throw "Invalid $Name '$Value'. Specify a Semantic Version without a leading 'v' (for example, '$($Value.Substring(1))')."
    }
    if ($Value -cnotmatch $script:SemVerPattern) {
        throw "Invalid $Name '$Value'. Specify a valid Semantic Version (MAJOR.MINOR.PATCH with optional -PRERELEASE)."
    }

    [pscustomobject]@{
        Value        = $Value
        Major        = $Matches['major']
        Minor        = $Matches['minor']
        Patch        = $Matches['patch']
        Prerelease   = $Matches['prerelease']
        IsPrerelease = [bool]$Matches['prerelease']
    }
}

function Resolve-ReleaseTagVersion {
    param([string] $Tag)

    if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -cnotmatch $script:ReleaseTagPattern) {
        throw "Invalid release tag '$Tag'. Release tags must follow vMAJOR.MINOR.PATCH (for example, 'v1.1.0')."
    }
    $Matches['version']
}

function Get-DocfxDefaultVersion {
    param([string] $RootPath = $script:RepoRoot)

    $dockerfilePath = Join-Path $RootPath 'Dockerfile'
    if (!(Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
        throw "Authoritative Dockerfile was not found at '$dockerfilePath'."
    }
    $dockerfile = Get-Content -LiteralPath $dockerfilePath -Raw
    if ($dockerfile -cnotmatch '(?m)^(?:\uFEFF)?ARG DOCFX_VERSION=(?<version>\S+)\r?$') {
        throw "Dockerfile does not declare 'ARG DOCFX_VERSION=<version>'."
    }
    (Resolve-SemVer $Matches['version'] 'DocfxVersion').Value
}

function Test-DocfxVersionConsistency {
    param([string] $RootPath = $script:RepoRoot)

    $expected = Get-DocfxDefaultVersion -RootPath $RootPath
    $generatorPath = Join-Path $RootPath 'framework-views/Build-DocfxFrameworkViews.ps1'
    $compatPath = Join-Path $RootPath 'templates/ms-style/framework-views.compat'

    $generator = Get-Content -LiteralPath $generatorPath -Raw
    if ($generator -cnotmatch "(?m)^\`$supportedDocfx = '$([regex]::Escape($expected))'\r?$") {
        throw "framework-views/Build-DocfxFrameworkViews.ps1 `$supportedDocfx does not match Dockerfile ARG DOCFX_VERSION ('$expected')."
    }

    $compat = (Get-Content -LiteralPath $compatPath -Raw).Trim()
    $expectedCompat = "framework-views-v1/docfx-$expected"
    if ($compat -cne $expectedCompat) {
        throw "templates/ms-style/framework-views.compat ('$compat') does not match expected '$expectedCompat'."
    }

    $expected
}

function Test-IsOfficialDocfxRepository {
    param([Parameter(Mandatory)][string] $Repository)

    $Repository -cin @('codebeltnet/docfx', 'docker.io/codebeltnet/docfx')
}

function Resolve-DocfxImageTagPlan {
    param(
        [Parameter(Mandatory)][pscustomobject] $CliVersion,
        [pscustomobject] $Engine,
        [Parameter(Mandatory)][string] $Repository
    )

    if ($Repository -cnotmatch $script:RepositoryPattern) {
        throw "Invalid Docker repository '$Repository'. Use lowercase repository segments without tags or whitespace."
    }

    $versionedBases = if ($CliVersion.IsPrerelease) {
        @($CliVersion.Value)
    } else {
        @($CliVersion.Value, "$($CliVersion.Major).$($CliVersion.Minor)", $CliVersion.Major)
    }

    $convenienceTags = if ($Engine -and $Engine.IsPrerelease) {
        @()
    } elseif ($CliVersion.IsPrerelease) {
        @($CliVersion.Value)
    } else {
        @($versionedBases + @('latest'))
    }

    $engineQualifiedTags = if ($Engine) {
        @($versionedBases | ForEach-Object { "$_-v$($Engine.Value)" })
    } else {
        @()
    }

    foreach ($convenienceTag in $convenienceTags) {
        if ($convenienceTag -cmatch $script:EngineSuffixPattern) {
            throw "Convenience tag '$convenienceTag' conflicts with the engine-qualified '-v<EngineVersion>' tag convention."
        }
    }

    $allTags = @($engineQualifiedTags) + @($convenienceTags)
    foreach ($candidate in $allTags) {
        if ($candidate.Length -gt 128 -or $candidate -cnotmatch $script:DockerTagPattern) {
            throw "Generated Docker tag '$candidate' violates Docker tag constraints (length $($candidate.Length), maximum 128)."
        }
    }

    [pscustomobject]@{
        Repository                = $Repository
        ConvenienceTags           = $convenienceTags
        EngineQualifiedTags       = $engineQualifiedTags
        AllTags                   = $allTags
        ConvenienceReferences     = @($convenienceTags | ForEach-Object { "${Repository}:$_" })
        EngineQualifiedReferences = @($engineQualifiedTags | ForEach-Object { "${Repository}:$_" })
        AllReferences             = @($allTags | ForEach-Object { "${Repository}:$_" })
    }
}

function Get-DocfxOciLabels {
    param(
        [Parameter(Mandatory)][pscustomobject] $CliVersion,
        [pscustomobject] $Engine,
        [string] $Revision,
        [string] $SourceRepository = $script:CanonicalSourceRepository,
        [string] $CreatedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    )

    $labels = [ordered]@{
        'org.opencontainers.image.created' = $CreatedUtc
        'org.opencontainers.image.source'  = $SourceRepository
    }
    if ($Revision) {
        $labels['org.opencontainers.image.revision'] = $Revision
    }
    if ($Engine) {
        $labels['org.opencontainers.image.version'] = $Engine.Value
        $labels['net.codebelt.docfx.engine.version'] = $Engine.Value
    }
    $labels['net.codebelt.docfx.cli.version'] = $CliVersion.Value
    $labels
}

function Get-DocfxSourceRevision {
    param(
        [switch] $Required,
        [string] $RootPath = $script:RepoRoot
    )

    $output = & git -C $RootPath rev-parse HEAD 2>&1
    $revision = ((@($output) | ForEach-Object { $_.ToString() }) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and $revision -cmatch '^[0-9a-f]{40}$') {
        return $revision
    }
    if ($Required) {
        throw 'A valid Git source revision is required (git rev-parse HEAD failed).'
    }
}

function Invoke-DocfxDocker {
    param([Parameter(Mandatory)][string[]] $Arguments)

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
}

function Assert-NativeDockerHost {
    param(
        [Parameter(Mandatory)][string] $Platform,
        [string] $DockerContext
    )

    $dockerArgs = if ($DockerContext) {
        @('--context', $DockerContext, 'info', '--format', '{{.OSType}}/{{.Architecture}}')
    } else {
        @('info', '--format', '{{.OSType}}/{{.Architecture}}')
    }
    $daemon = & docker @dockerArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot access native Docker host for '$Platform'."
    }
    $normalized = ((@($daemon) | ForEach-Object { $_.ToString() }) -join '').Trim().Replace('x86_64', 'amd64').Replace('aarch64', 'arm64')
    if ($normalized -cne $Platform) {
        throw "Native Docker host required for '$Platform'; got '$normalized'. Emulation is insufficient for native validation."
    }
}

function Test-SkopeoTransport {
    if (Get-Command skopeo -ErrorAction SilentlyContinue) {
        return $true
    }

    $dockerHost = if (-not $env:DOCKER_CONTEXT) { $env:DOCKER_HOST } else { $null }
    if (-not $dockerHost) {
        $output = & docker context inspect --format '{{.Endpoints.docker.Host}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect active Docker context for Skopeo utility transport.'
        }
        $dockerHost = ((@($output) | ForEach-Object { $_.ToString() }) -join '').Trim()
    }

    if ($dockerHost -notmatch '^(unix|npipe)://') {
        throw 'Native Skopeo is required when the active Docker daemon uses SSH or TCP; install skopeo locally or select a local Docker context.'
    }
    return $false
}

function Invoke-Skopeo {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $CaptureOutput
    )

    $useNative = Test-SkopeoTransport
    if ($useNative) {
        if ($CaptureOutput) {
            $stdoutFile = New-TemporaryFile
            $stderrFile = New-TemporaryFile
            try {
                $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command skopeo).Source)
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                foreach ($arg in $Arguments) { $psi.ArgumentList.Add($arg) }
                $proc = [System.Diagnostics.Process]::Start($psi)
                $stderrTask = $proc.StandardError.ReadToEndAsync()
                $stdoutStream = [IO.File]::OpenWrite($stdoutFile.FullName)
                try {
                    $proc.StandardOutput.BaseStream.CopyTo($stdoutStream)
                } finally {
                    $stdoutStream.Dispose()
                }
                $proc.WaitForExit()
                $stderrText = $stderrTask.GetAwaiter().GetResult()
                if ($proc.ExitCode -ne 0) {
                    throw "skopeo $($Arguments[0]) exited with code $($proc.ExitCode): $($stderrText.Trim())"
                }
                return [IO.File]::ReadAllBytes($stdoutFile.FullName)
            } finally {
                Remove-Item -LiteralPath $stdoutFile.FullName, $stderrFile.FullName -Force -ErrorAction SilentlyContinue
            }
        }

        & skopeo @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "skopeo $($Arguments[0]) exited with code $LASTEXITCODE."
        }
        return
    }

    $dockerArgs = [System.Collections.Generic.List[string]]::new()
    $dockerArgs.AddRange([string[]]@('run', '--rm', '--user', '0'))
    $converted = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        if ($arg -match '^(?<transport>oci-archive|oci|docker-archive):(?<rest>.+)$') {
            $transport = $Matches['transport']
            $rest = $Matches['rest']
            $suffix = ''
            if ($transport -ceq 'docker-archive' -and $rest -match '^(?<file>.+\.tar):(?<tag>.+)$') {
                $localPath = $Matches['file']
                $suffix = ':' + $Matches['tag']
            } else {
                $localPath = $rest
            }
            $fullPath = [IO.Path]::GetFullPath($localPath)
            $parent = [IO.Path]::GetDirectoryName($fullPath)
            $leaf = [IO.Path]::GetFileName($fullPath)
            $mount = "/archive$i"
            $dockerArgs.AddRange([string[]]@('--volume', "${parent}:${mount}"))
            $converted.Add("${transport}:${mount}/${leaf}${suffix}")
        } else {
            $converted.Add($arg)
        }
    }

    if ($env:REGISTRY_AUTH_FILE) {
        $authPath = [IO.Path]::GetFullPath($env:REGISTRY_AUTH_FILE)
        $dockerArgs.AddRange([string[]]@('--volume', "${authPath}:/auth.json:ro", '--env', 'REGISTRY_AUTH_FILE=/auth.json'))
    }
    $dockerArgs.Add($script:SkopeoUtilityImage)
    $dockerArgs.AddRange($converted)

    if ($CaptureOutput) {
        $rawText = & docker @($dockerArgs.ToArray()) 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errText = ((@($rawText) | ForEach-Object { $_.ToString() }) -join "`n").Trim()
            throw "skopeo $($Arguments[0]) exited with code $LASTEXITCODE`: $errText"
        }
        $joined = (@($rawText) | ForEach-Object { $_.ToString() }) -join "`n"
        return [Text.UTF8Encoding]::new($false).GetBytes($joined)
    }

    Invoke-DocfxDocker ($dockerArgs.ToArray())
}

function Invoke-OciArtifact {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $RootPath = $script:RepoRoot
    )

    $toolPath = Join-Path $RootPath 'tools/OciArtifact.cs'
    $output = & dotnet run --file $toolPath -- @Arguments 2>&1
    $lines = @($output | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw "OciArtifact $($Arguments[0]) failed (exit $LASTEXITCODE): $($lines -join "`n")"
    }
    $lines -join "`n"
}

function Get-RegistryManifestDigest {
    param([Parameter(Mandatory)][string] $Reference)

    try {
        $raw = Invoke-Skopeo -Arguments @('inspect', '--raw', "docker://$Reference") -CaptureOutput
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        return "sha256:$hash"
    } catch {
        $message = $_.Exception.Message
        if ($message -match '(?i)\b(?:manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN)\b') {
            return $null
        }
        throw "Could not inspect registry reference '$Reference': $message"
    }
}

function Assert-EngineTagAvailableForBuild {
    param([Parameter(Mandatory)][string] $Reference)

    $output = & docker buildx imagetools inspect --format '{{json .Manifest}}' $Reference 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output) | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -eq 0) {
        $detail = if ($text -cmatch '"digest"\s*:\s*"(sha256:[0-9a-f]{64})"') { " ($($Matches[1]))" } else { '' }
        throw "Published engine-qualified tag '$Reference' already exists in the registry$detail. Refusing to reassign an existing release tag; increment -EngineVersion for a new release."
    }
    if ($text -notmatch '(?i)(?:not found|manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN)') {
        throw "Could not verify whether engine-qualified tag '$Reference' exists in the registry (docker exit code $exitCode): $text"
    }
}

function Test-DocfxPromotionPreflight {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $EngineVersion,
        [Parameter(Mandatory)][string] $DocfxVersion,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Tags,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $EngineQualifiedTags,
        [string] $SourceRepository = $script:CanonicalSourceRepository,
        [string] $ExpectedIndexDigest,
        [string] $Platform,
        [switch] $RequireEngineTagsPresent
    )

    $null = Resolve-SemVer $EngineVersion 'EngineVersion'
    $null = Resolve-SemVer $DocfxVersion 'DocfxVersion'

    if ($Tags.Count -eq 0) {
        throw 'Promotion requires at least one destination tag.'
    }
    if ($EngineQualifiedTags.Count -eq 0) {
        throw 'Promotion requires explicit engine-qualified destination tags.'
    }
    if (@($Tags | Select-Object -Unique).Count -ne $Tags.Count -or @($EngineQualifiedTags | Select-Object -Unique).Count -ne $EngineQualifiedTags.Count) {
        throw 'Promotion destination tags must be unique.'
    }

    $repos = @($Tags -replace ':[^/:]+$' | Select-Object -Unique)
    if ($repos.Count -ne 1) {
        throw 'All promotion destination tags must target one repository.'
    }

    foreach ($engineTag in $EngineQualifiedTags) {
        if ($engineTag -cnotin $Tags) {
            throw "Engine-qualified tag '$engineTag' must be included in destination tags."
        }
        if (-not $engineTag.EndsWith("-v$EngineVersion", [StringComparison]::Ordinal)) {
            throw "Engine-qualified tag '$engineTag' does not match engine version '$EngineVersion'."
        }
    }

    $null = Invoke-OciArtifact -Arguments @('check-seal', $ArchivePath)
    $verifyArgs = @('verify', $ArchivePath, '--version', $EngineVersion, '--docfx-version', $DocfxVersion, '--revision', $Revision, '--source', $SourceRepository, '--no-seal')
    if ($Platform) { $verifyArgs += @('--platform', $Platform) }
    if ($ExpectedIndexDigest) { $verifyArgs += @('--expected-digest', $ExpectedIndexDigest) }
    $verified = Invoke-OciArtifact -Arguments $verifyArgs | ConvertFrom-Json
    $digest = $verified.indexDigest

    foreach ($tag in $EngineQualifiedTags) {
        $existing = Get-RegistryManifestDigest -Reference $tag
        if ($null -eq $existing) {
            if ($RequireEngineTagsPresent) {
                throw "Required engine-qualified tag '$tag' is absent in the registry before convenience tag promotion."
            }
        } elseif ($existing -cne $digest) {
            throw "Engine-qualified tag conflict for '$tag': expected '$digest', found '$existing'. Refusing to overwrite an existing release."
        }
    }

    [pscustomobject]@{
        IndexDigest = $digest
        Platforms   = @($verified.platforms)
        Configs     = $verified.configs
        Repository  = $repos[0]
    }
}

function Publish-DocfxOciArchive {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $EngineVersion,
        [Parameter(Mandatory)][string] $DocfxVersion,
        [Parameter(Mandatory)][string] $Revision,
        [Parameter(Mandatory)][string[]] $Tags,
        [Parameter(Mandatory)][string[]] $EngineQualifiedTags,
        [string] $SourceRepository = $script:CanonicalSourceRepository,
        [string] $ExpectedIndexDigest,
        [string] $Platform,
        [scriptblock] $BeforeConvenience
    )

    $preflight = Test-DocfxPromotionPreflight `
        -ArchivePath $ArchivePath `
        -EngineVersion $EngineVersion `
        -DocfxVersion $DocfxVersion `
        -Revision $Revision `
        -Tags $Tags `
        -EngineQualifiedTags $EngineQualifiedTags `
        -SourceRepository $SourceRepository `
        -ExpectedIndexDigest $ExpectedIndexDigest `
        -Platform $Platform

    $expectedDigest = $preflight.IndexDigest
    $convenienceTags = @($Tags | Where-Object { $_ -cnotin $EngineQualifiedTags })
    $layoutDir = Join-Path ([IO.Path]::GetTempPath()) ('docfx-oci-layout-' + [guid]::NewGuid().ToString('N'))
    $published = [System.Collections.Generic.List[object]]::new()

    try {
        $null = Invoke-OciArtifact -Arguments @('extract-layout', $ArchivePath, '--output-dir', $layoutDir)

        foreach ($tag in $EngineQualifiedTags) {
            $existing = Get-RegistryManifestDigest -Reference $tag
            if ($null -ne $existing -and $existing -cne $expectedDigest) {
                throw "Engine-qualified tag conflict for '$tag': expected '$expectedDigest', found '$existing'. Refusing to overwrite."
            }
            if ($null -eq $existing) {
                Invoke-Skopeo -Arguments @('copy', '--all', '--preserve-digests', "oci:$layoutDir", "docker://$tag")
            }

            $raw = Invoke-Skopeo -Arguments @('inspect', '--raw', "docker://$tag") -CaptureOutput
            $actualDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
            if ($actualDigest -cne $expectedDigest) {
                throw "Registry OCI index digest changed for '$tag': expected '$expectedDigest', found '$actualDigest'."
            }
            $published.Add([pscustomobject]@{ tag = $tag; digest = $actualDigest; family = 'engine-qualified' })
        }

        if ($convenienceTags.Count -gt 0) {
            if ($BeforeConvenience) {
                & $BeforeConvenience
            }

            $null = Test-DocfxPromotionPreflight `
                -ArchivePath $ArchivePath `
                -EngineVersion $EngineVersion `
                -DocfxVersion $DocfxVersion `
                -Revision $Revision `
                -Tags $Tags `
                -EngineQualifiedTags $EngineQualifiedTags `
                -SourceRepository $SourceRepository `
                -ExpectedIndexDigest $expectedDigest `
                -Platform $Platform `
                -RequireEngineTagsPresent

            foreach ($tag in $convenienceTags) {
                Invoke-Skopeo -Arguments @('copy', '--all', '--preserve-digests', "oci:$layoutDir", "docker://$tag")
                $raw = Invoke-Skopeo -Arguments @('inspect', '--raw', "docker://$tag") -CaptureOutput
                $actualDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
                if ($actualDigest -cne $expectedDigest) {
                    throw "Registry OCI index digest changed for '$tag': expected '$expectedDigest', found '$actualDigest'."
                }
                $published.Add([pscustomobject]@{ tag = $tag; digest = $actualDigest; family = 'convenience' })
            }
        }

        # Download promoted content once by immutable digest and re-verify full OCI archive integrity.
        $verifyDir = Join-Path ([IO.Path]::GetTempPath()) ('docfx-registry-verify-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
        try {
            $downloaded = Join-Path $verifyDir 'registry.oci.tar'
            Invoke-Skopeo -Arguments @('copy', '--all', '--preserve-digests', "docker://$($preflight.Repository)@$expectedDigest", "oci-archive:$downloaded")
            $verifyArgs = @('verify', $downloaded, '--version', $EngineVersion, '--docfx-version', $DocfxVersion, '--revision', $Revision, '--source', $SourceRepository, '--expected-digest', $expectedDigest, '--no-seal')
            if ($Platform) { $verifyArgs += @('--platform', $Platform) }
            $null = Invoke-OciArtifact -Arguments $verifyArgs
        } finally {
            if (Test-Path -LiteralPath $verifyDir) {
                Remove-Item -LiteralPath $verifyDir -Recurse -Force
            }
        }
    } finally {
        if (Test-Path -LiteralPath $layoutDir) {
            Remove-Item -LiteralPath $layoutDir -Recurse -Force
        }
    }

    $records = $published.ToArray()
    ConvertTo-Json -InputObject $records -Depth 5 | Set-Content -LiteralPath "$ArchivePath.published.json" -Encoding utf8NoBOM

    if ($env:GITHUB_STEP_SUMMARY) {
        $summaryLines = @(
            '### Promoted DocFX Docker Hub Images'
            ''
            "- DocFX CLI: $DocfxVersion"
            "- Codebelt engine: $EngineVersion"
            "- Source revision: $Revision"
            "- Verified OCI index digest: ``$expectedDigest``"
            "- Engine-qualified tags: $($EngineQualifiedTags -join ', ')"
            "- Convenience tags: $($convenienceTags -join ', ')"
            ''
        )
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join "`n") -Encoding utf8NoBOM
    }

    [pscustomobject]@{
        IndexDigest = $expectedDigest
        Repository  = $preflight.Repository
        Published   = $records
    }
}

Export-ModuleMember -Function @(
    'Resolve-SemVer'
    'Resolve-ReleaseTagVersion'
    'Get-DocfxDefaultVersion'
    'Test-DocfxVersionConsistency'
    'Test-IsOfficialDocfxRepository'
    'Resolve-DocfxImageTagPlan'
    'Get-DocfxOciLabels'
    'Get-DocfxSourceRevision'
    'Invoke-DocfxDocker'
    'Assert-NativeDockerHost'
    'Test-SkopeoTransport'
    'Invoke-Skopeo'
    'Invoke-OciArtifact'
    'Get-RegistryManifestDigest'
    'Assert-EngineTagAvailableForBuild'
    'Test-DocfxPromotionPreflight'
    'Publish-DocfxOciArchive'
)
