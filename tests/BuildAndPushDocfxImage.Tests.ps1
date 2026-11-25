BeforeAll {
    $repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/..").Path
    $buildScript = (Resolve-Path -LiteralPath "$PSScriptRoot/../BuildAndPushDocfxImage.ps1").Path
    $modulePath = (Resolve-Path -LiteralPath "$PSScriptRoot/../tools/DocfxImage.psm1").Path
    Import-Module $modulePath -Force

    $validRevision = 'a' * 40
    $validIndexDigest = 'sha256:' + ('1' * 64)
    $arm64Digest = 'sha256:' + ('2' * 64)
    $amd64Digest = 'sha256:' + ('3' * 64)
    $attestationDigest = 'sha256:' + ('4' * 64)

    function Get-ArgumentValues([string[]] $Arguments, [string] $Flag) {
        $values = [System.Collections.Generic.List[string]]::new()
        for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
            if ($Arguments[$i] -ceq $Flag) {
                $values.Add($Arguments[$i + 1])
            }
        }
        ,$values.ToArray()
    }
}

Describe 'BuildAndPushDocfxImage versioning, OCI build-only, and safeguards' {
    BeforeEach {
        $global:DocfxBuildTestState = @{
            DockerCalls = [System.Collections.Generic.List[object]]::new()
            SkopeoCalls = [System.Collections.Generic.List[object]]::new()
            OciCalls    = [System.Collections.Generic.List[object]]::new()
            GitState    = @{
                ExitCode = 0
                Output   = $validRevision
            }
            DockerState = @{
                HasPushed          = $false
                BuildExitCode      = 0
                BuildDigest        = $validIndexDigest
                IndexDigest        = $validIndexDigest
                IndexMediaType     = 'application/vnd.oci.image.index.v1+json'
                PreflightResponses = @{}
                ManifestResponses  = @{}
                ImageResponses     = @{}
                Manifests          = @(
                    @{
                        mediaType = 'application/vnd.oci.image.manifest.v1+json'
                        digest    = $arm64Digest
                        platform  = @{ os = 'linux'; architecture = 'arm64' }
                    }
                    @{
                        mediaType = 'application/vnd.oci.image.manifest.v1+json'
                        digest    = $amd64Digest
                        platform  = @{ os = 'linux'; architecture = 'amd64' }
                    }
                    @{
                        mediaType   = 'application/vnd.oci.image.manifest.v1+json'
                        digest      = $attestationDigest
                        annotations = @{ 'vnd.docker.reference.type' = 'attestation-manifest' }
                        platform    = @{ os = 'unknown'; architecture = 'unknown' }
                    }
                )
                ImageLabels        = @{
                    'org.opencontainers.image.version'  = '1.1.0'
                    'net.codebelt.docfx.engine.version' = '1.1.0'
                    'net.codebelt.docfx.cli.version'    = '2.81.0'
                    'org.opencontainers.image.revision' = $validRevision
                }
            }
        }

        Mock -ModuleName DocfxImage git {
            $global:LASTEXITCODE = $global:DocfxBuildTestState.GitState.ExitCode
            return $global:DocfxBuildTestState.GitState.Output
        }

        Mock -ModuleName DocfxImage docker {
            $state = $global:DocfxBuildTestState
            $ds = $state.DockerState
            $callArgs = @($args)
            $state.DockerCalls.Add($callArgs)
            $global:LASTEXITCODE = 0

            if ($callArgs.Count -ge 1 -and $callArgs[0] -ceq 'info') {
                return 'linux/x86_64'
            }
            if ($callArgs.Count -ge 2 -and $callArgs[0] -ceq 'image' -and $callArgs[1] -ceq 'inspect') {
                return (@(@{ Id = 'sha256:' + ('7' * 64); Size = 123456 }) | ConvertTo-Json -Depth 4)
            }
            if ($callArgs.Count -ge 1 -and ($callArgs[0] -ceq 'load' -or $callArgs[0] -ceq 'tag')) {
                return
            }
            if ($callArgs.Count -ge 2 -and $callArgs[0] -ceq 'buildx' -and $callArgs[1] -ceq 'build') {
                if ($ds.BuildExitCode -ne 0) {
                    $global:LASTEXITCODE = $ds.BuildExitCode
                    return
                }
                if ($callArgs -contains '--push') {
                    $ds.HasPushed = $true
                }
                $outIndex = [Array]::IndexOf($callArgs, '--output')
                if ($outIndex -ge 0 -and $callArgs[$outIndex + 1] -match 'dest=(.+)$') {
                    $destPath = $Matches[1]
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destPath) | Out-Null
                    Set-Content -LiteralPath $destPath -Value 'synthetic-oci-tar'
                }
                $metadataIndex = [Array]::IndexOf($callArgs, '--metadata-file')
                if ($metadataIndex -ge 0) {
                    $metadataPath = $callArgs[$metadataIndex + 1]
                    @{ 'containerimage.digest' = $ds.BuildDigest } |
                        ConvertTo-Json |
                        Set-Content -LiteralPath $metadataPath
                }
                return
            }
            if ($callArgs.Count -ge 3 -and $callArgs[0] -ceq 'buildx' -and $callArgs[1] -ceq 'imagetools' -and $callArgs[2] -ceq 'inspect') {
                $formatIndex = [Array]::IndexOf($callArgs, '--format')
                $format = $callArgs[$formatIndex + 1]
                $reference = $callArgs[-1]

                if ($format -ceq '{{json .Manifest}}') {
                    if (-not $ds.HasPushed) {
                        if ($ds.PreflightResponses.ContainsKey($reference)) {
                            $response = $ds.PreflightResponses[$reference]
                            $global:LASTEXITCODE = $response.ExitCode
                            return $response.Output
                        }
                        $global:LASTEXITCODE = 1
                        return "ERROR: docker.io/${reference}: not found"
                    }
                    if ($ds.ManifestResponses.ContainsKey($reference)) {
                        $response = $ds.ManifestResponses[$reference]
                        $global:LASTEXITCODE = $response.ExitCode
                        return $response.Output
                    }
                    return (@{
                        schemaVersion = 2
                        mediaType     = $ds.IndexMediaType
                        digest        = $ds.IndexDigest
                        manifests     = $ds.Manifests
                    } | ConvertTo-Json -Depth 6)
                }

                if ($format -ceq '{{json .Image}}') {
                    if ($ds.ImageResponses.ContainsKey($reference)) {
                        $response = $ds.ImageResponses[$reference]
                        $global:LASTEXITCODE = $response.ExitCode
                        return $response.Output
                    }
                    $arch = if ($reference.EndsWith("@$arm64Digest")) { 'arm64' } else { 'amd64' }
                    return (@{
                        os           = 'linux'
                        architecture = $arch
                        config       = @{ Labels = $ds.ImageLabels }
                    } | ConvertTo-Json -Depth 6)
                }
            }
        }
    }

    AfterEach {
        Remove-Variable DocfxBuildTestState -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'Local builds, offline planning, and convenience tag generation' {
        It 'supports offline -WhatIf -PassThru planning without invoking Docker or Git' {
            $plan = & $buildScript -EngineVersion '1.1.0' -BuildOnly -Platform 'linux/amd64' -WhatIf -PassThru

            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 0
            $plan.DocfxVersion | Should -Be '2.81.0'
            $plan.EngineVersion | Should -Be '1.1.0'
            $plan.Repository | Should -Be 'codebeltnet/docfx'
            $plan.EngineQualifiedTags | Should -Be @(
                'codebeltnet/docfx:2.81.0-v1.1.0'
                'codebeltnet/docfx:2.81-v1.1.0'
                'codebeltnet/docfx:2-v1.1.0'
            )
            $plan.ConvenienceTags | Should -Be @(
                'codebeltnet/docfx:2.81.0'
                'codebeltnet/docfx:2.81'
                'codebeltnet/docfx:2'
                'codebeltnet/docfx:latest'
            )

            $silent = & $buildScript -Tag docfx-local -WhatIf
            $silent | Should -BeNullOrEmpty
        }

        It 'preserves existing convenience tags when EngineVersion is omitted locally' {
            $plan = & $buildScript -Tag docfx-local -PassThru

            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 1
            $buildArgs = $global:DocfxBuildTestState.DockerCalls[0]
            $tags = Get-ArgumentValues $buildArgs '--tag'
            $labels = Get-ArgumentValues $buildArgs '--label'

            $tags | Should -Be @('docfx-local:2.81.0', 'docfx-local:2.81', 'docfx-local:2', 'docfx-local:latest')
            $buildArgs | Should -Contain '--load'
            $buildArgs | Should -Not -Contain '--push'
            $labels | Should -Contain 'net.codebelt.docfx.cli.version=2.81.0'
            $labels | Should -Contain "org.opencontainers.image.revision=$validRevision"
            ($labels | Where-Object { $_ -like 'org.opencontainers.image.version=*' }) | Should -BeNullOrEmpty
            ($labels | Where-Object { $_ -like 'net.codebelt.docfx.engine.version=*' }) | Should -BeNullOrEmpty
            $plan.EngineVersion | Should -BeNullOrEmpty
        }

        It 'builds all seven convenience and engine-qualified tags locally when EngineVersion is supplied' {
            & $buildScript -Tag docfx-local -EngineVersion 1.1.0 -Platform linux/amd64 `
                -FrameworkSdkImage 'example.invalid/sdk:11-amd64' `
                -FrameworkSdkArm64Image 'example.invalid/sdk:11-arm64'

            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 1
            $buildArgs = $global:DocfxBuildTestState.DockerCalls[0]
            $tags = Get-ArgumentValues $buildArgs '--tag'
            $labels = Get-ArgumentValues $buildArgs '--label'
            $buildArgValues = Get-ArgumentValues $buildArgs '--build-arg'

            $tags | Should -Be @(
                'docfx-local:2.81.0-v1.1.0'
                'docfx-local:2.81-v1.1.0'
                'docfx-local:2-v1.1.0'
                'docfx-local:2.81.0'
                'docfx-local:2.81'
                'docfx-local:2'
                'docfx-local:latest'
            )
            $labels | Should -Contain 'org.opencontainers.image.version=1.1.0'
            $labels | Should -Contain 'net.codebelt.docfx.engine.version=1.1.0'
            $labels | Should -Contain 'net.codebelt.docfx.cli.version=2.81.0'
            $labels | Should -Contain "org.opencontainers.image.revision=$validRevision"
            $buildArgValues | Should -Contain 'DOCFX_VERSION=2.81.0'
            $buildArgValues | Should -Contain 'DOTNET_VERSION=10.0'
            $buildArgValues | Should -Contain 'FRAMEWORK_SDK_IMAGE=example.invalid/sdk:11-amd64'
            $buildArgValues | Should -Contain 'FRAMEWORK_SDK_ARM64_IMAGE=example.invalid/sdk:11-arm64'
            (Get-ArgumentValues $buildArgs '--platform') | Should -Be @('linux/amd64')
        }

        It 'allows local builds without a Git repository by omitting the revision label' {
            $global:DocfxBuildTestState.GitState.ExitCode = 128
            $global:DocfxBuildTestState.GitState.Output = 'fatal: not a git repository'

            & $buildScript -Tag docfx-local -EngineVersion 1.1.0

            $labels = Get-ArgumentValues $global:DocfxBuildTestState.DockerCalls[0] '--label'
            ($labels | Where-Object { $_ -like 'org.opencontainers.image.revision=*' }) | Should -BeNullOrEmpty
        }

        It 'fails when docker buildx build exits non-zero' {
            $global:DocfxBuildTestState.DockerState.BuildExitCode = 42
            { & $buildScript -Tag docfx-local } | Should -Throw '*exited with code 42*'
        }
    }

    Context 'Build-once OCI export and native validation mode (-BuildOnly)' {
        It 'rejects combining -BuildOnly and -Publish or omitting -EngineVersion' {
            { & $buildScript -BuildOnly -Publish -EngineVersion '1.1.0' } | Should -Throw '*Cannot combine -BuildOnly and -Publish*'
            { & $buildScript -BuildOnly } | Should -Throw '*Build-only OCI export requires an explicit -EngineVersion*'
        }

        It 'exports OCI archive with SBOM/provenance, verifies, loads via Skopeo, verifies config, and writes metadata' {
            Mock Test-SkopeoTransport { return $true }
            Mock Invoke-Skopeo {
                param([string[]] $Arguments)
                $global:DocfxBuildTestState.SkopeoCalls.Add($Arguments)
                if ($Arguments[-1] -match '^docker-archive:(.+\.tar):') {
                    Set-Content -LiteralPath $Matches[1] -Value 'docker-tar'
                }
            }
            Mock Invoke-OciArtifact {
                param([string[]] $Arguments)
                $global:DocfxBuildTestState.OciCalls.Add($Arguments)
                if ($Arguments[0] -ceq 'verify') {
                    return (@{ indexDigest = $validIndexDigest; archiveSha256 = ('e' * 64); platforms = @('amd64'); configs = @{ amd64 = 'sha256:' + ('5' * 64) } } | ConvertTo-Json -Compress)
                }
                return 'sha256:' + ('5' * 64)
            }

            $tempOut = Join-Path $TestDrive 'oci-build'
            $archivePath = Join-Path $tempOut 'docfx.amd64.oci.tar'
            $metadataPath = Join-Path $tempOut 'docfx-image.json'

            $record = & $buildScript -BuildOnly -EngineVersion '1.1.0' -Platform 'linux/amd64' -RequireNative -SkipContainerTest `
                -ArchivePath $archivePath -MetadataFile $metadataPath -PassThru

            $record.DocfxVersion | Should -Be '2.81.0'
            $record.EngineVersion | Should -Be '1.1.0'
            $record.Platform | Should -Be 'linux/amd64'
            $record.ConfigDigest | Should -Be ('sha256:' + ('5' * 64))
            $record.NativeVerified | Should -BeFalse
            Test-Path -LiteralPath $metadataPath | Should -BeTrue
            $global:DocfxBuildTestState.SkopeoCalls.Count | Should -Be 1
            $global:DocfxBuildTestState.OciCalls.Count | Should -Be 2

            $buildCall = @($global:DocfxBuildTestState.DockerCalls | Where-Object { $_[0] -ceq 'buildx' -and $_[1] -ceq 'build' })[0]
            $buildCall | Should -Contain '--sbom=true'
            $buildCall | Should -Contain '--provenance=mode=max'

            $nullOut = & $buildScript -BuildOnly -EngineVersion '1.1.0' -SkipContainerTest -ContainerRegistry '' -Tag 'docfx' `
                -ArchivePath (Join-Path $tempOut 'docfx-default.oci.tar') -MetadataFile (Join-Path $tempOut 'docfx-default.json')
            $nullOut | Should -BeNullOrEmpty
        }

        It 'invokes tests/Test-DocfxContainer.ps1 when -SkipContainerTest is not set' {
            Mock Test-SkopeoTransport { return $true }
            Mock Invoke-Skopeo {
                param([string[]] $Arguments)
                if ($Arguments[-1] -match '^docker-archive:(.+\.tar):') {
                    Set-Content -LiteralPath $Matches[1] -Value 'docker-tar'
                }
            }
            Mock Invoke-OciArtifact {
                param([string[]] $Arguments)
                if ($Arguments[0] -ceq 'verify') {
                    return (@{ indexDigest = $validIndexDigest; archiveSha256 = ('e' * 64); platforms = @('amd64'); configs = @{ amd64 = 'sha256:' + ('5' * 64) } } | ConvertTo-Json -Compress)
                }
                return 'sha256:' + ('5' * 64)
            }

            $tempOut = Join-Path $TestDrive 'oci-build-verify'
            function global:docker { $global:LASTEXITCODE = 99; 'sentinel-container-test-invoked' }
            try {
                { & $buildScript -BuildOnly -EngineVersion '1.1.0' -Platform 'linux/amd64' `
                    -ArchivePath (Join-Path $tempOut 'docfx.oci.tar') -MetadataFile (Join-Path $tempOut 'docfx.json') } |
                    Should -Throw '*sentinel-container-test-invoked*'
            } finally {
                Remove-Item Function:global:docker -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Independent versions, future releases, and prerelease handling' {
        It 'generates independent tags for <CaseName>' -ForEach @(
            @{
                CaseName = 'engine patch bump with same CLI'
                Docfx    = '2.81.0'
                Engine   = '1.1.1'
                Expected = @('docfx:2.81.0-v1.1.1', 'docfx:2.81-v1.1.1', 'docfx:2-v1.1.1', 'docfx:2.81.0', 'docfx:2.81', 'docfx:2', 'docfx:latest')
            }
            @{
                CaseName = 'future major CLI and engine versions'
                Docfx    = '3.0.0'
                Engine   = '2.0.0'
                Expected = @('docfx:3.0.0-v2.0.0', 'docfx:3.0-v2.0.0', 'docfx:3-v2.0.0', 'docfx:3.0.0', 'docfx:3.0', 'docfx:3', 'docfx:latest')
            }
            @{
                CaseName = 'prerelease engine does not move floating convenience tags'
                Docfx    = '2.81.0'
                Engine   = '1.2.0-rc.1'
                Expected = @('docfx:2.81.0-v1.2.0-rc.1', 'docfx:2.81-v1.2.0-rc.1', 'docfx:2-v1.2.0-rc.1')
            }
            @{
                CaseName = 'prerelease CLI with stable engine emits only exact CLI tags'
                Docfx    = '2.82.0-preview.1'
                Engine   = '1.2.0'
                Expected = @('docfx:2.82.0-preview.1-v1.2.0', 'docfx:2.82.0-preview.1')
            }
            @{
                CaseName = 'prerelease CLI with prerelease engine emits only exact combined tag'
                Docfx    = '2.82.0-preview.1'
                Engine   = '1.2.0-alpha.0a'
                Expected = @('docfx:2.82.0-preview.1-v1.2.0-alpha.0a')
            }
        ) {
            & $buildScript -DocfxVersion $Docfx -EngineVersion $Engine
            $tags = Get-ArgumentValues $global:DocfxBuildTestState.DockerCalls[0] '--tag'
            $tags | Should -Be $Expected
        }

        It 'emits only exact prerelease CLI tag locally when EngineVersion is omitted' {
            & $buildScript -DocfxVersion '2.82.0-preview.1' -Tag docfx-local
            $tags = Get-ArgumentValues $global:DocfxBuildTestState.DockerCalls[0] '--tag'
            $tags | Should -Be @('docfx-local:2.82.0-preview.1')
        }
    }

    Context 'Semantic Versioning and Docker tag validation' {
        It 'rejects invalid EngineVersion <Version>' -ForEach @(
            @{ Version = ''; Expected = '*must not be empty*' }
            @{ Version = '   '; Expected = '*must not be empty*' }
            @{ Version = 'v1.1.0'; Expected = "*without a leading 'v'*" }
            @{ Version = '1.1.0+build.1'; Expected = '*build metadata*' }
            @{ Version = '01.1.0'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0-01'; Expected = '*valid Semantic Version*' }
            @{ Version = 'latest'; Expected = '*valid Semantic Version*' }
        ) {
            { & $buildScript -EngineVersion $Version } | Should -Throw $Expected
            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 0
        }

        It 'rejects invalid DocfxVersion <Version>' -ForEach @(
            @{ Version = ''; Expected = '*DocfxVersion must not be empty*' }
            @{ Version = 'v2.81.0'; Expected = "*without a leading 'v'*" }
            @{ Version = '2.81.0+sha.abc'; Expected = '*build metadata*' }
            @{ Version = '2.81'; Expected = '*valid Semantic Version*' }
        ) {
            { & $buildScript -DocfxVersion $Version } | Should -Throw $Expected
            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 0
        }

        It 'rejects combined tags exceeding 128 characters or conflicting convenience tags' {
            $longCli = '2.81.0-' + ('a' * 116)
            { & $buildScript -DocfxVersion $longCli -EngineVersion '1.1.0' } | Should -Throw '*violates Docker tag constraints*maximum 128*'
            { & $buildScript -DocfxVersion '2.81.0-v1.1.0' -EngineVersion '1.1.0' } | Should -Throw '*conflicts with the engine-qualified*'
        }

        It 'rejects invalid Docker repository names' {
            { & $buildScript -Tag 'Docfx' } | Should -Throw '*Invalid Docker repository*'
            { & $buildScript -Tag 'docfx' -ContainerRegistry 'INVALID/REG' -EngineVersion '1.1.0' -Publish } | Should -Throw '*Invalid Docker repository*'
        }
    }

    Context 'Publication safeguards, official production protection, and custom registry verification' {
        It 'refuses direct -Publish to official codebeltnet/docfx production repository' {
            { & $buildScript -EngineVersion '1.1.0' -Publish } | Should -Throw '*Direct publication to official repository*disabled*build-once promotion*'
            { & $buildScript -ContainerRegistry 'docker.io/codebeltnet/' -EngineVersion '1.1.0' -Publish } | Should -Throw '*Direct publication to official repository*disabled*'
            $global:DocfxBuildTestState.DockerCalls.Count | Should -Be 0
        }

        It 'requires an explicit EngineVersion and valid platforms and Git revision when publishing to custom registries' {
            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -Publish } | Should -Throw '*Publishing requires an explicit -EngineVersion*'
            { & $buildScript -Platform 'linux/386' } | Should -Throw '*Supported builder platforms are linux/amd64 and linux/arm64*'
            { & $buildScript -Platform 'linux/amd64,linux/arm64' } | Should -Throw '*builds one platform at a time*'
            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Platform 'linux/amd64' -Publish } | Should -Throw "*Specify exactly one platform for 'linux/arm64'*"

            $global:DocfxBuildTestState.GitState.ExitCode = 128
            $global:DocfxBuildTestState.GitState.Output = 'fatal: not a git repository'
            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish } | Should -Throw '*valid Git source revision*'
        }

        It 'refuses to reassign an already published engine-qualified tag on a custom registry' {
            $global:DocfxBuildTestState.DockerState.PreflightResponses['localhost:5000/team/docfx:2.81-v1.1.0'] = @{
                ExitCode = 0
                Output   = '{"digest":"sha256:' + ('9' * 64) + '"}'
            }

            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish } |
                Should -Throw "*localhost:5000/team/docfx:2.81-v1.1.0*already exists*Refusing to reassign*"

            $global:DocfxBuildTestState.DockerState.PreflightResponses['localhost:5000/team/docfx:2.81.0-v1.1.0'] = @{
                ExitCode = 0
                Output   = '{}'
            }
            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish } |
                Should -Throw '*already exists in the registry. Refusing to reassign*'
        }

        It 'fails closed on unexpected registry errors during preflight' {
            $global:DocfxBuildTestState.DockerState.PreflightResponses['localhost:5000/team/docfx:2.81.0-v1.1.0'] = @{
                ExitCode = 1
                Output   = 'ERROR: unauthorized: authentication required'
            }

            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish } |
                Should -Throw '*Could not verify whether engine-qualified tag*unauthorized*'
        }

        It 'publishes once to a custom registry, checks all seven tags, verifies both platforms and OCI labels' {
            $output = & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish
            $output | Should -BeExactly "localhost:5000/team/docfx:2.81.0-v1.1.0@$validIndexDigest"

            $global:DocfxBuildTestState.DockerState.HasPushed = $false
            $global:DocfxBuildTestState.DockerState.IndexMediaType = 'application/vnd.docker.distribution.manifest.list.v2+json'
            $output2 = & $buildScript -ContainerRegistry '' -Tag 'docfx' -EngineVersion '1.1.0' -Publish
            $output2 | Should -BeExactly "docfx:2.81.0-v1.1.0@$validIndexDigest"
        }

        It 'diagnoses post-publish verification failures on custom registries for <Scenario>' -ForEach @(
            @{
                Scenario = 'invalid buildx metadata digest'
                Setup    = { $global:DocfxBuildTestState.DockerState.BuildDigest = 'not-a-digest' }
                Expected = '*valid published image digest*'
            }
            @{
                Scenario = 'tag resolving to a different index digest'
                Setup    = { $global:DocfxBuildTestState.DockerState.IndexDigest = 'sha256:' + ('f' * 64) }
                Expected = '*does not resolve to image index*'
            }
            @{
                Scenario = 'tag resolving to a non-index mediaType'
                Setup    = { $global:DocfxBuildTestState.DockerState.IndexMediaType = 'application/vnd.oci.image.manifest.v1+json' }
                Expected = '*does not resolve to image index*'
            }
            @{
                Scenario = 'missing platform manifest in image index'
                Setup    = { $global:DocfxBuildTestState.DockerState.Manifests = @($global:DocfxBuildTestState.DockerState.Manifests | Where-Object { $_.platform.architecture -cne 'arm64' }) }
                Expected = "*does not identify one image manifest for 'linux/arm64'*"
            }
            @{
                Scenario = 'mismatched platform OS/architecture in image config'
                Setup    = {
                    $global:DocfxBuildTestState.DockerState.ImageResponses["localhost:5000/team/docfx@$arm64Digest"] = @{
                        ExitCode = 0
                        Output   = (@{ os = 'linux'; architecture = 'amd64'; config = @{ Labels = $global:DocfxBuildTestState.DockerState.ImageLabels } } | ConvertTo-Json -Depth 5)
                    }
                }
                Expected = "*Published image config for 'linux/arm64' reports 'linux/amd64'*"
            }
            @{
                Scenario = 'mismatched OCI engine version label'
                Setup    = { $global:DocfxBuildTestState.DockerState.ImageLabels['org.opencontainers.image.version'] = '1.0.1' }
                Expected = "*reports label 'org.opencontainers.image.version' as '1.0.1' instead of '1.1.0'*"
            }
            @{
                Scenario = 'missing OCI labels object'
                Setup    = { $global:DocfxBuildTestState.DockerState.ImageLabels = $null }
                Expected = "*reports label 'org.opencontainers.image.version' as '' instead of '1.1.0'*"
            }
        ) {
            & $Setup
            { & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.1.0' -Publish } | Should -Throw $Expected
        }
    }
}
