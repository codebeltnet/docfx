#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline)]
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $DocfxVersion = '2.81.0',
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

function Invoke-Docker([string[]] $Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
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

$major, $minor = $DocfxVersion.Split('.')[0..1]
$references = @($DocfxVersion, "$major.$minor", $major, 'latest') | ForEach-Object { "${repository}:$_" }
$buildArguments = @(
    'buildx', 'build', '--file', $DockerFile
    '--build-arg', "DOCFX_VERSION=$DocfxVersion"
    '--build-arg', "DOTNET_VERSION=$DotnetVersion"
    if ($FrameworkSdkImage) { '--build-arg'; "FRAMEWORK_SDK_IMAGE=$FrameworkSdkImage" }
    if ($FrameworkSdkArm64Image) { '--build-arg'; "FRAMEWORK_SDK_ARM64_IMAGE=$FrameworkSdkArm64Image" }
    if ($platforms) { '--platform'; ($platforms -join ',') }
    foreach ($reference in $references) { '--tag'; $reference }
)

if (!$Publish) {
    Invoke-Docker ($buildArguments + @('--load', '.'))
    return
}

$metadataFile = New-TemporaryFile
try {
    Invoke-Docker ($buildArguments + @('--push', '--metadata-file', $metadataFile.FullName, '.'))
    $digest = (Get-Content -LiteralPath $metadataFile.FullName -Raw | ConvertFrom-Json).'containerimage.digest'
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw 'Buildx did not report a valid published image digest.' }

    foreach ($reference in $references) {
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
    }

    Write-Output "$($references[0])@$digest"
} finally {
    Remove-Item -LiteralPath $metadataFile.FullName
}
