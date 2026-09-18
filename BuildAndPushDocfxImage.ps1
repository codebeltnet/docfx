param(
    [Parameter(ValueFromPipeline)]
    [string]$DocfxVersion="2.80.1",
    [Parameter(ValueFromPipeline)]
    [string]$DotnetVersion="10.0",
    [Parameter(ValueFromPipeline)]
    [string]$Tag="docfx",
    [Parameter(ValueFromPipeline)]
    [string]$ContainerRegistry="codebeltnet/",
    [Parameter(ValueFromPipeline)]
    [string]$Platform="linux/arm64,linux/amd64",
    [Parameter(ValueFromPipeline)]
    [string]$DockerFile="Dockerfile"
)
$MajorMinorVersion = ($DocfxVersion -split '\.')[0..1] -join '.'
$MajorVersion = ($DocfxVersion -split '\.')[0]

Invoke-Expression "docker buildx build --build-arg=DOCFX_VERSION=$($DocfxVersion) --build-arg=DOTNET_VERSION=$($DotnetVersion) -t $($Tag):$($DocfxVersion) -t $($Tag):$($MajorMinorVersion) -t $($Tag):$($MajorVersion) -t $($Tag):latest --platform $($Platform) --load -f Dockerfile ."
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):$($DocfxVersion)"
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):$($MajorMinorVersion)"
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):$($MajorVersion)"
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):latest"
# Invoke-Expression "docker push $($ContainerRegistry)$($Tag):$($DocfxVersion)"
# Invoke-Expression "docker push $($ContainerRegistry)$($Tag):$($MajorMinorVersion)"
# Invoke-Expression "docker push $($ContainerRegistry)$($Tag):$($MajorVersion)"
# Invoke-Expression "docker push $($ContainerRegistry)$($Tag):latest"
