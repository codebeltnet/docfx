param(
    [Parameter(ValueFromPipeline)]
    [string]$DocfxVersion="2.77.0",
    [Parameter(ValueFromPipeline)]
    [string]$DotnetVersion="8.0",
    [Parameter(ValueFromPipeline)]
    [string]$Tag="docfx",
    [Parameter(ValueFromPipeline)]
    [string]$ContainerRegistry="codebeltnet/",
    [Parameter(ValueFromPipeline)]
    [string]$Platform="linux/arm64,linux/amd64",
    [Parameter(ValueFromPipeline)]
    [string]$DockerFile="Dockerfile"
)
Invoke-Expression "docker buildx build --build-arg=DOCFX_VERSION=$($DocfxVersion) --build-arg=DOTNET_VERSION=$($DotnetVersion) -t $($Tag):$($DocfxVersion) -t $($Tag):latest --platform $($Platform) --load -f Dockerfile ."
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):$($DocfxVersion)"
Invoke-Expression "docker tag $($Tag):$($DocfxVersion) $($ContainerRegistry)$($Tag):latest"
Invoke-Expression "docker push $($ContainerRegistry)$($Tag):$($DocfxVersion)"
Invoke-Expression "docker push $($ContainerRegistry)$($Tag):latest"
