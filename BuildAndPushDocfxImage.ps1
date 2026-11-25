#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(ValueFromPipeline)]
    [string] $DocfxVersion,
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
    [string] $SourceRepository = 'https://github.com/codebeltnet/docfx',
    [string] $ArchivePath = './artifacts/docfx.oci.tar',
    [string] $MetadataFile = './artifacts/docfx-image.json',
    [switch] $BuildOnly,
    [switch] $RequireNative,
    [switch] $SkipContainerTest,
    [switch] $Publish,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

Import-Module (Join-Path $PSScriptRoot 'tools/DocfxImage.psm1')

if ($BuildOnly -and $Publish) {
    throw 'Cannot combine -BuildOnly and -Publish. Use -BuildOnly for build-once OCI export and validation.'
}

$resolvedDocfxInput = if ($PSBoundParameters.ContainsKey('DocfxVersion')) {
    $DocfxVersion
} else {
    Get-DocfxDefaultVersion -RootPath $PSScriptRoot
}
$cli = Resolve-SemVer $resolvedDocfxInput 'DocfxVersion'

if (($Publish -or $BuildOnly) -and [string]::IsNullOrWhiteSpace($EngineVersion)) {
    $modeName = if ($Publish) { 'Publishing' } else { 'Build-only OCI export' }
    throw "$modeName requires an explicit -EngineVersion (for example, -EngineVersion 1.1.0)."
}
$engine = if ($PSBoundParameters.ContainsKey('EngineVersion') -or $EngineVersion) {
    Resolve-SemVer $EngineVersion 'EngineVersion'
}

$requiredPlatforms = @('linux/arm64', 'linux/amd64')
[string[]] $platforms = if ($Platform) {
    @($Platform.Split(',') | ForEach-Object { $_.Trim() })
} elseif ($Publish) {
    $requiredPlatforms
} elseif ($BuildOnly) {
    @('linux/' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant().Replace('x64', 'amd64'))
} else {
    [string[]]@()
}

if (@($platforms).Count -gt 0 -and @($platforms -cnotmatch '^linux/(arm64|amd64)(?:/[^/]+)?$').Count -gt 0) {
    throw 'Supported builder platforms are linux/amd64 and linux/arm64.'
}

$repository = if ($Publish -or $BuildOnly) {
    if ($ContainerRegistry) { "$($ContainerRegistry.TrimEnd('/'))/$Tag" } else { $Tag }
} else {
    $Tag
}

if ($Publish) {
    if (Test-IsOfficialDocfxRepository -Repository $repository) {
        throw "Direct publication to official repository '$repository' is disabled to enforce build-once promotion. Tag a vMAJOR.MINOR.PATCH release to run release.yml and publish the draft GitHub release to trigger deploy.yml."
    }
    foreach ($required in $requiredPlatforms) {
        if (@($platforms -cmatch "^$required(?:/[^/]+)?$").Count -ne 1) {
            throw "Specify exactly one platform for '$required' when publishing."
        }
    }
} elseif (@($platforms).Count -gt 1) {
    throw 'A local or build-only invocation builds one platform at a time. Specify one platform or omit -Platform to use the host default.'
}

$tagPlan = Resolve-DocfxImageTagPlan -CliVersion $cli -Engine $engine -Repository $repository
$plan = [pscustomobject]@{
    DocfxVersion        = $cli.Value
    EngineVersion       = if ($engine) { $engine.Value } else { $null }
    DotnetVersion       = $DotnetVersion
    Repository          = $repository
    SourceRepository    = $SourceRepository
    DockerFile          = $DockerFile
    Platforms           = $platforms
    Tags                = $tagPlan.AllReferences
    ConvenienceTags     = $tagPlan.ConvenienceReferences
    EngineQualifiedTags = $tagPlan.EngineQualifiedReferences
    ArchivePath         = [IO.Path]::GetFullPath($ArchivePath)
    MetadataFile        = [IO.Path]::GetFullPath($MetadataFile)
    BuildOnly           = [bool]$BuildOnly
    Published           = $false
}

$action = if ($Publish) { 'Build and publish Docker image' } elseif ($BuildOnly) { 'Build, export OCI archive, and validate Docker image' } else { 'Build and load local Docker image' }
if (-not $PSCmdlet.ShouldProcess($tagPlan.AllReferences[0], $action)) {
    if ($PassThru) { return $plan }
    return
}

$revision = Get-DocfxSourceRevision -Required:($Publish -or $BuildOnly) -RootPath $PSScriptRoot
$labels = Get-DocfxOciLabels -CliVersion $cli -Engine $engine -Revision $revision -SourceRepository $SourceRepository

$buildArguments = [System.Collections.Generic.List[string]]::new()
$buildArguments.AddRange([string[]]@(
    'buildx', 'build', '--file', $DockerFile
    '--build-arg', "DOCFX_VERSION=$($cli.Value)"
    '--build-arg', "DOTNET_VERSION=$DotnetVersion"
))
if ($FrameworkSdkImage) { $buildArguments.AddRange([string[]]@('--build-arg', "FRAMEWORK_SDK_IMAGE=$FrameworkSdkImage")) }
if ($FrameworkSdkArm64Image) { $buildArguments.AddRange([string[]]@('--build-arg', "FRAMEWORK_SDK_ARM64_IMAGE=$FrameworkSdkArm64Image")) }
foreach ($labelKey in $labels.Keys) {
    $buildArguments.AddRange([string[]]@('--label', "$labelKey=$($labels[$labelKey])"))
}
if (@($platforms).Count -gt 0) {
    $buildArguments.AddRange([string[]]@('--platform', ($platforms -join ',')))
}

if ($BuildOnly) {
    $targetPlatform = $platforms[0]
    $cpu = ($targetPlatform -split '/')[1]
    if ($RequireNative) {
        Assert-NativeDockerHost -Platform $targetPlatform
    }
    $null = Test-SkopeoTransport

    $archiveFullPath = [IO.Path]::GetFullPath($ArchivePath)
    $metadataFullPath = [IO.Path]::GetFullPath($MetadataFile)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $archiveFullPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $metadataFullPath) | Out-Null

    $ociArgs = @($buildArguments.ToArray()) + @(
        '--output', "type=oci,name=$($tagPlan.AllReferences[0]),dest=$archiveFullPath"
        '--sbom=true'
        '--provenance=mode=max'
        '.'
    )
    Invoke-DocfxDocker $ociArgs | Out-Host

    $verified = Invoke-OciArtifact -Arguments @(
        'verify', $archiveFullPath
        '--version', $engine.Value
        '--docfx-version', $cli.Value
        '--revision', $revision
        '--source', $SourceRepository
        '--platform', $cpu
    ) -RootPath $PSScriptRoot | ConvertFrom-Json

    $localImage = "docfx-verify:${cpu}-$([guid]::NewGuid().ToString('N'))"
    $loadArchive = Join-Path ([IO.Path]::GetTempPath()) "docfx-load-${cpu}-$([guid]::NewGuid().ToString('N')).docker.tar"
    try {
        $null = Invoke-Skopeo -Arguments @('copy', '--override-os', 'linux', '--override-arch', $cpu, "oci-archive:$archiveFullPath", "docker-archive:${loadArchive}:${localImage}")
        Invoke-DocfxDocker @('load', '--input', $loadArchive) | Out-Host
    } finally {
        if (Test-Path -LiteralPath $loadArchive) {
            Remove-Item -LiteralPath $loadArchive -Force
        }
    }

    if (-not $SkipContainerTest) {
        & (Join-Path $PSScriptRoot 'tests/Test-DocfxContainer.ps1') `
            -Image $localImage `
            -Platform $targetPlatform `
            -DocfxVersion $cli.Value `
            -EngineVersion $engine.Value `
            -Revision $revision `
            -SourceRepository $SourceRepository `
            -RequireNative:$RequireNative
    }

    $loadedConfigDigest = (Invoke-OciArtifact -Arguments @(
        'loaded-config', $archiveFullPath
        '--platform', $cpu
        '--image', $localImage
    ) -RootPath $PSScriptRoot).Trim()

    $details = @((Invoke-DocfxDocker @('image', 'inspect', $localImage)) -join "`n" | ConvertFrom-Json)[0]

    foreach ($reference in $tagPlan.AllReferences) {
        Invoke-DocfxDocker @('tag', $localImage, $reference) | Out-Host
    }

    $record = [pscustomobject]@{
        DocfxVersion        = $cli.Value
        EngineVersion       = $engine.Value
        DotnetVersion       = $DotnetVersion
        Repository          = $repository
        SourceRepository    = $SourceRepository
        SourceCommit        = $revision
        Platform            = $targetPlatform
        Architecture        = $cpu
        Tags                = $tagPlan.AllReferences
        ConvenienceTags     = $tagPlan.ConvenienceReferences
        EngineQualifiedTags = $tagPlan.EngineQualifiedReferences
        ArchivePath         = $archiveFullPath
        ArchiveSha256       = $verified.archiveSha256
        OciArchiveBytes     = (Get-Item -LiteralPath $archiveFullPath).Length
        ConfigDigest        = $loadedConfigDigest
        ImageId             = $details.Id
        SizeBytes           = $details.Size
        NativeVerified      = (-not $SkipContainerTest)
        CreatedUtc          = $labels['org.opencontainers.image.created']
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataFullPath -Encoding utf8NoBOM

    if ($PassThru) { return $record }
    return
}

foreach ($reference in $tagPlan.AllReferences) {
    $buildArguments.AddRange([string[]]@('--tag', $reference))
}

if (-not $Publish) {
    Invoke-DocfxDocker ($buildArguments.ToArray() + @('--load', '.')) | Out-Host
    if ($PassThru) { return $plan }
    return
}

foreach ($reference in $tagPlan.EngineQualifiedReferences) {
    Assert-EngineTagAvailableForBuild $reference
}

$metadataTemp = New-TemporaryFile
try {
    Invoke-DocfxDocker ($buildArguments.ToArray() + @('--push', '--metadata-file', $metadataTemp.FullName, '.')) | Out-Host
    $digest = (Get-Content -LiteralPath $metadataTemp.FullName -Raw | ConvertFrom-Json).'containerimage.digest'
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Buildx did not report a valid published image digest.'
    }

    $index = $null
    foreach ($reference in $tagPlan.AllReferences) {
        $index = Invoke-DocfxDocker @('buildx', 'imagetools', 'inspect', '--format', '{{json .Manifest}}', $reference) |
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
        $image = Invoke-DocfxDocker @('buildx', 'imagetools', 'inspect', '--format', '{{json .Image}}', "$repository@$($manifest[0].digest)") |
            ConvertFrom-Json
        if ($image.os -cne $os -or $image.architecture -cne $architecture) {
            throw "Published image config for '$required' reports '$($image.os)/$($image.architecture)'."
        }
        $actualLabels = $image.config.Labels
        $expectedLabels = [ordered]@{
            'org.opencontainers.image.version'  = $engine.Value
            'net.codebelt.docfx.engine.version' = $engine.Value
            'net.codebelt.docfx.cli.version'    = $cli.Value
            'org.opencontainers.image.revision' = $revision
        }
        foreach ($labelName in $expectedLabels.Keys) {
            $actualValue = if ($actualLabels) { $actualLabels.$labelName }
            if ($actualValue -cne $expectedLabels[$labelName]) {
                throw "Published image config for '$required' reports label '$labelName' as '$actualValue' instead of '$($expectedLabels[$labelName])'."
            }
        }
    }

    Write-Output "$($tagPlan.AllReferences[0])@$digest"
} finally {
    Remove-Item -LiteralPath $metadataTemp.FullName
}
