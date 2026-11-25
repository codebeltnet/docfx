#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [string] $DocfxVersion = '2.81.0',
    [Parameter(ValueFromPipeline)]
    [string] $EngineVersion,
    [Parameter(ValueFromPipeline)]
    [string] $DotnetVersion = '10.0',
    [Parameter(ValueFromPipeline)]
    [string] $Tag = 'docfx',
    [Parameter(ValueFromPipeline)]
    [string] $ContainerRegistry = 'codebeltnet/',
    [Parameter(ValueFromPipeline)]
    [string] $Platform,
    [Parameter(ValueFromPipeline)]
    [string] $DockerFile = 'Dockerfile',
    [string] $FrameworkSdkImage,
    [string] $FrameworkSdkArm64Image,
    [switch] $Publish
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$semVerPattern = '^(?<major>0|[1-9][0-9]*)\.(?<minor>0|[1-9][0-9]*)\.(?<patch>0|[1-9][0-9]*)(?:-(?<prerelease>(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
$dockerTagPattern = '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
$engineSuffixPattern = '-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$'
$repositoryPattern = '^(?:[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::[0-9]+)?/)?[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|[-]+)[a-z0-9]+)*)*$'

function Resolve-SemVer([string] $Value, [string] $Name) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must not be empty. Specify a Semantic Version such as '1.1.0'."
    }
    if ($Value.Contains('+')) {
        throw "Invalid $Name '$Value'. Semantic Versioning build metadata ('+...') is not valid in Docker image tags."
    }
    if ($Value -cmatch '^v\d') {
        throw "Invalid $Name '$Value'. Specify a Semantic Version without a leading 'v' (for example, '$($Value.Substring(1))')."
    }
    if ($Value -cnotmatch $semVerPattern) {
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

function Resolve-ImageTagPlan([pscustomobject] $CliVersion, [pscustomobject] $Engine, [string] $Repository) {
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
        if ($convenienceTag -cmatch $engineSuffixPattern) {
            throw "Convenience tag '$convenienceTag' conflicts with the engine-qualified '-v<EngineVersion>' tag convention."
        }
    }
    $allTags = @($engineQualifiedTags) + @($convenienceTags)
    foreach ($candidate in $allTags) {
        if ($candidate.Length -gt 128 -or $candidate -cnotmatch $dockerTagPattern) {
            throw "Generated Docker tag '$candidate' violates Docker tag constraints (length $($candidate.Length), maximum 128)."
        }
    }
    [pscustomobject]@{
        ConvenienceTags           = $convenienceTags
        EngineQualifiedTags       = $engineQualifiedTags
        AllTags                   = $allTags
        ConvenienceReferences     = @($convenienceTags | ForEach-Object { "${Repository}:$_" })
        EngineQualifiedReferences = @($engineQualifiedTags | ForEach-Object { "${Repository}:$_" })
        AllReferences             = @($allTags | ForEach-Object { "${Repository}:$_" })
    }
}

function Invoke-Docker([string[]] $Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
}

function Assert-EngineTagAvailable([string] $Reference) {
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

function Get-SourceRevision([switch] $Required) {
    $output = & git -C $PSScriptRoot rev-parse HEAD 2>&1
    $revision = ((@($output) | ForEach-Object { $_.ToString() }) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and $revision -cmatch '^[0-9a-f]{40}$') {
        return $revision
    }
    if ($Required) {
        throw 'Publishing requires a valid Git source revision (git rev-parse HEAD failed).'
    }
}

$cli = Resolve-SemVer $DocfxVersion 'DocfxVersion'
if ($Publish -and [string]::IsNullOrWhiteSpace($EngineVersion)) {
    throw "Publishing requires an explicit -EngineVersion (for example, -EngineVersion 1.1.0)."
}
$engine = if ($PSBoundParameters.ContainsKey('EngineVersion') -or $EngineVersion) {
    Resolve-SemVer $EngineVersion 'EngineVersion'
}

$requiredPlatforms = 'linux/arm64', 'linux/amd64'
[string[]] $platforms = if ($Platform) { $Platform.Split(',').Trim() } elseif ($Publish) { $requiredPlatforms }
if ($platforms -and @($platforms -cnotmatch '^linux/(arm64|amd64)(?:/[^/]+)?$').Count) {
    throw 'Supported builder platforms are linux/amd64 and linux/arm64.'
}
$repository = $Tag
if ($Publish) {
    foreach ($required in $requiredPlatforms) {
        if (@($platforms -cmatch "^$required(?:/[^/]+)?$").Count -ne 1) {
            throw "Specify exactly one platform for '$required' when publishing."
        }
    }
    if ($ContainerRegistry) { $repository = "$($ContainerRegistry.TrimEnd('/'))/$Tag" }
} elseif ($platforms.Count -gt 1) {
    throw 'A local build loads one platform. Specify one platform or omit -Platform to use the builder default.'
}
if ($repository -cnotmatch $repositoryPattern) {
    throw "Invalid Docker repository '$repository'. Use lowercase repository segments without tags or whitespace."
}

$tagPlan = Resolve-ImageTagPlan $cli $engine $repository
$revision = Get-SourceRevision -Required:$Publish
$created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

$buildArguments = @(
    'buildx', 'build', '--file', $DockerFile
    '--build-arg', "DOCFX_VERSION=$($cli.Value)"
    '--build-arg', "DOTNET_VERSION=$DotnetVersion"
    if ($FrameworkSdkImage) { '--build-arg'; "FRAMEWORK_SDK_IMAGE=$FrameworkSdkImage" }
    if ($FrameworkSdkArm64Image) { '--build-arg'; "FRAMEWORK_SDK_ARM64_IMAGE=$FrameworkSdkArm64Image" }
    '--label', "org.opencontainers.image.created=$created"
    if ($revision) { '--label'; "org.opencontainers.image.revision=$revision" }
    if ($engine) {
        '--label'; "org.opencontainers.image.version=$($engine.Value)"
        '--label'; "net.codebelt.docfx.engine.version=$($engine.Value)"
    }
    '--label', "net.codebelt.docfx.cli.version=$($cli.Value)"
    if ($platforms) { '--platform'; ($platforms -join ',') }
    foreach ($reference in $tagPlan.AllReferences) { '--tag'; $reference }
)

if (!$Publish) {
    Invoke-Docker ($buildArguments + @('--load', '.'))
    return
}

foreach ($reference in $tagPlan.EngineQualifiedReferences) {
    Assert-EngineTagAvailable $reference
}

$metadataFile = New-TemporaryFile
try {
    Invoke-Docker ($buildArguments + @('--push', '--metadata-file', $metadataFile.FullName, '.'))
    $digest = (Get-Content -LiteralPath $metadataFile.FullName -Raw | ConvertFrom-Json).'containerimage.digest'
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Buildx did not report a valid published image digest.' }

    foreach ($reference in $tagPlan.AllReferences) {
        $index = Invoke-Docker @('buildx', 'imagetools', 'inspect', '--format', '{{json .Manifest}}', $reference) |
            ConvertFrom-Json
        if ($index.digest -cne $digest -or $index.mediaType -cnotin @(
            'application/vnd.oci.image.index.v1+json', 'application/vnd.docker.distribution.manifest.list.v2+json'
        )) {
            throw "Published tag '$reference' does not resolve to image index '$digest'."
        }
    }
    foreach ($required in $requiredPlatforms) {
        $os, $architecture = $required.Split('/')
        $manifest = @($index.manifests | Where-Object {
            $_.platform.os -ceq $os -and $_.platform.architecture -ceq $architecture -and $_.mediaType -cin @(
                'application/vnd.oci.image.manifest.v1+json', 'application/vnd.docker.distribution.manifest.v2+json'
            )
        })
        if ($manifest.Count -ne 1 -or $manifest[0].digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
            throw "Published image index '$digest' does not identify one image manifest for '$required'."
        }
        $image = Invoke-Docker @('buildx', 'imagetools', 'inspect', '--format', '{{json .Image}}', "$repository@$($manifest[0].digest)") |
            ConvertFrom-Json
        if ($image.os -cne $os -or $image.architecture -cne $architecture) {
            throw "Published image config for '$required' reports '$($image.os)/$($image.architecture)'."
        }
        $labels = $image.config.Labels
        $expectedLabels = [ordered]@{
            'org.opencontainers.image.version'  = $engine.Value
            'net.codebelt.docfx.engine.version' = $engine.Value
            'net.codebelt.docfx.cli.version'    = $cli.Value
            'org.opencontainers.image.revision' = $revision
        }
        foreach ($labelName in $expectedLabels.Keys) {
            $actualValue = if ($labels) { $labels.$labelName }
            if ($actualValue -cne $expectedLabels[$labelName]) {
                throw "Published image config for '$required' reports label '$labelName' as '$actualValue' instead of '$($expectedLabels[$labelName])'."
            }
        }
    }

    Write-Output "$($tagPlan.AllReferences[0])@$digest"
} finally {
    Remove-Item -LiteralPath $metadataFile.FullName
}
