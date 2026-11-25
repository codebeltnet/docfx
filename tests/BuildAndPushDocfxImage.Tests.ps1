BeforeAll {
    $buildScript = (Resolve-Path -LiteralPath "$PSScriptRoot/../BuildAndPushDocfxImage.ps1").Path
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

    function git {
        $gitCalls.Add(@($args))
        if ($gitState.ExitCode -ne 0) {
            $global:LASTEXITCODE = $gitState.ExitCode
            return $gitState.Output
        }
        $global:LASTEXITCODE = 0
        return $gitState.Output
    }

    function docker {
        $callArgs = @($args)
        $dockerCalls.Add($callArgs)
        $global:LASTEXITCODE = 0

        if ($callArgs.Count -ge 2 -and $callArgs[0] -ceq 'buildx' -and $callArgs[1] -ceq 'build') {
            if ($dockerState.BuildExitCode -ne 0) {
                $global:LASTEXITCODE = $dockerState.BuildExitCode
                return
            }
            if ($callArgs -contains '--push') {
                $dockerState.HasPushed = $true
            }
            $metadataIndex = [Array]::IndexOf($callArgs, '--metadata-file')
            if ($metadataIndex -ge 0) {
                $metadataPath = $callArgs[$metadataIndex + 1]
                @{ 'containerimage.digest' = $dockerState.BuildDigest } |
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
                if (!$dockerState.HasPushed) {
                    if ($dockerState.PreflightResponses.ContainsKey($reference)) {
                        $response = $dockerState.PreflightResponses[$reference]
                        $global:LASTEXITCODE = $response.ExitCode
                        return $response.Output
                    }
                    $global:LASTEXITCODE = 1
                    return "ERROR: docker.io/${reference}: not found"
                }

                if ($dockerState.ManifestResponses.ContainsKey($reference)) {
                    $response = $dockerState.ManifestResponses[$reference]
                    $global:LASTEXITCODE = $response.ExitCode
                    return $response.Output
                }

                return (@{
                    schemaVersion = 2
                    mediaType     = $dockerState.IndexMediaType
                    digest        = $dockerState.IndexDigest
                    manifests     = $dockerState.Manifests
                } | ConvertTo-Json -Depth 6)
            }

            if ($format -ceq '{{json .Image}}') {
                if ($dockerState.ImageResponses.ContainsKey($reference)) {
                    $response = $dockerState.ImageResponses[$reference]
                    $global:LASTEXITCODE = $response.ExitCode
                    return $response.Output
                }
                $arch = if ($reference.EndsWith("@$arm64Digest")) { 'arm64' } else { 'amd64' }
                return (@{
                    os           = 'linux'
                    architecture = $arch
                    config       = @{
                        Labels = $dockerState.ImageLabels
                    }
                } | ConvertTo-Json -Depth 6)
            }
        }
    }
}

Describe 'BuildAndPushDocfxImage versioning, metadata, and safeguards' {
    BeforeEach {
        $previousExitCode = $global:LASTEXITCODE
        $dockerCalls = [System.Collections.Generic.List[object]]::new()
        $gitCalls = [System.Collections.Generic.List[object]]::new()
        $gitState = @{
            ExitCode = 0
            Output   = $validRevision
        }
        $dockerState = @{
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

    AfterEach {
        $global:LASTEXITCODE = $previousExitCode
    }

    Context 'Local builds and convenience tag generation' {
        It 'preserves existing convenience tags when EngineVersion is omitted locally' {
            & $buildScript -Tag docfx-local

            $dockerCalls.Count | Should -Be 1
            $buildArgs = $dockerCalls[0]
            $tags = Get-ArgumentValues $buildArgs '--tag'
            $labels = Get-ArgumentValues $buildArgs '--label'

            $tags | Should -Be @('docfx-local:2.81.0', 'docfx-local:2.81', 'docfx-local:2', 'docfx-local:latest')
            $buildArgs | Should -Contain '--load'
            $buildArgs | Should -Not -Contain '--push'
            $labels | Should -Contain 'net.codebelt.docfx.cli.version=2.81.0'
            $labels | Should -Contain "org.opencontainers.image.revision=$validRevision"
            ($labels | Where-Object { $_ -like 'org.opencontainers.image.version=*' }) | Should -BeNullOrEmpty
            ($labels | Where-Object { $_ -like 'net.codebelt.docfx.engine.version=*' }) | Should -BeNullOrEmpty
        }

        It 'builds all seven convenience and engine-qualified tags locally when EngineVersion is supplied' {
            & $buildScript -Tag docfx-local -EngineVersion 1.1.0 -Platform linux/amd64 `
                -FrameworkSdkImage 'example.invalid/sdk:11-amd64' `
                -FrameworkSdkArm64Image 'example.invalid/sdk:11-arm64'

            $dockerCalls.Count | Should -Be 1
            $buildArgs = $dockerCalls[0]
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
            ($labels | Where-Object { $_ -cmatch '^org\.opencontainers\.image\.created=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' }).Count | Should -Be 1
            $buildArgValues | Should -Contain 'DOCFX_VERSION=2.81.0'
            $buildArgValues | Should -Contain 'DOTNET_VERSION=10.0'
            $buildArgValues | Should -Contain 'FRAMEWORK_SDK_IMAGE=example.invalid/sdk:11-amd64'
            $buildArgValues | Should -Contain 'FRAMEWORK_SDK_ARM64_IMAGE=example.invalid/sdk:11-arm64'
            (Get-ArgumentValues $buildArgs '--platform') | Should -Be @('linux/amd64')
        }

        It 'allows local builds without a Git repository by omitting the revision label' {
            $gitState.ExitCode = 128
            $gitState.Output = 'fatal: not a git repository'

            & $buildScript -Tag docfx-local -EngineVersion 1.1.0

            $labels = Get-ArgumentValues $dockerCalls[0] '--label'
            ($labels | Where-Object { $_ -like 'org.opencontainers.image.revision=*' }) | Should -BeNullOrEmpty
        }

        It 'fails when docker buildx build exits non-zero' {
            $dockerState.BuildExitCode = 42

            { & $buildScript -Tag docfx-local } | Should -Throw '*exited with code 42*'
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
                CaseName = 'engine minor bump with same CLI'
                Docfx    = '2.81.0'
                Engine   = '1.2.0'
                Expected = @('docfx:2.81.0-v1.2.0', 'docfx:2.81-v1.2.0', 'docfx:2-v1.2.0', 'docfx:2.81.0', 'docfx:2.81', 'docfx:2', 'docfx:latest')
            }
            @{
                CaseName = 'future major CLI and engine versions'
                Docfx    = '3.0.0'
                Engine   = '2.0.0'
                Expected = @('docfx:3.0.0-v2.0.0', 'docfx:3.0-v2.0.0', 'docfx:3-v2.0.0', 'docfx:3.0.0', 'docfx:3.0', 'docfx:3', 'docfx:latest')
            }
            @{
                CaseName = 'multi-digit future minor and patch versions'
                Docfx    = '10.12.3'
                Engine   = '4.5.6'
                Expected = @('docfx:10.12.3-v4.5.6', 'docfx:10.12-v4.5.6', 'docfx:10-v4.5.6', 'docfx:10.12.3', 'docfx:10.12', 'docfx:10', 'docfx:latest')
            }
            @{
                CaseName = 'zero major versions'
                Docfx    = '0.9.1'
                Engine   = '0.2.2'
                Expected = @('docfx:0.9.1-v0.2.2', 'docfx:0.9-v0.2.2', 'docfx:0-v0.2.2', 'docfx:0.9.1', 'docfx:0.9', 'docfx:0', 'docfx:latest')
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

            $tags = Get-ArgumentValues $dockerCalls[0] '--tag'
            $tags | Should -Be $Expected
        }

        It 'emits only exact prerelease CLI tag locally when EngineVersion is omitted' {
            & $buildScript -DocfxVersion '2.82.0-preview.1' -Tag docfx-local

            $tags = Get-ArgumentValues $dockerCalls[0] '--tag'
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
            @{ Version = '1.01.0'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.01'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0.0'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0-01'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0-'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0-rc..1'; Expected = '*valid Semantic Version*' }
            @{ Version = '1.1.0-rc_1'; Expected = '*valid Semantic Version*' }
            @{ Version = 'latest'; Expected = '*valid Semantic Version*' }
        ) {
            { & $buildScript -EngineVersion $Version } | Should -Throw $Expected
            $dockerCalls.Count | Should -Be 0
        }

        It 'rejects invalid DocfxVersion <Version>' -ForEach @(
            @{ Version = ''; Expected = '*DocfxVersion must not be empty*' }
            @{ Version = 'v2.81.0'; Expected = "*without a leading 'v'*" }
            @{ Version = '2.81.0+sha.abc'; Expected = '*build metadata*' }
            @{ Version = '02.81.0'; Expected = '*valid Semantic Version*' }
            @{ Version = '2.81'; Expected = '*valid Semantic Version*' }
        ) {
            { & $buildScript -DocfxVersion $Version } | Should -Throw $Expected
            $dockerCalls.Count | Should -Be 0
        }

        It 'rejects combined tags that exceed the 128-character Docker tag limit' {
            $longCli = '2.81.0-' + ('a' * 116)
            { & $buildScript -DocfxVersion $longCli -EngineVersion '1.1.0' } | Should -Throw '*violates Docker tag constraints*maximum 128*'
            $dockerCalls.Count | Should -Be 0
        }

        It 'rejects a prerelease CLI tag that conflicts with the engine-qualified tag convention' {
            { & $buildScript -DocfxVersion '2.81.0-v1.1.0' -EngineVersion '1.1.0' } | Should -Throw '*conflicts with the engine-qualified*'
            $dockerCalls.Count | Should -Be 0
        }

        It 'rejects invalid Docker repository names' -ForEach @(
            @{ TagValue = 'Docfx'; Registry = 'codebeltnet/'; PublishFlag = $false }
            @{ TagValue = 'docfx:extra'; Registry = 'codebeltnet/'; PublishFlag = $false }
            @{ TagValue = 'docfx bad'; Registry = 'codebeltnet/'; PublishFlag = $false }
            @{ TagValue = 'docfx'; Registry = 'INVALID/REG'; PublishFlag = $true }
        ) {
            $params = @{ Tag = $TagValue; ContainerRegistry = $Registry }
            if ($PublishFlag) { $params.Publish = $true; $params.EngineVersion = '1.1.0' }
            { & $buildScript @params } | Should -Throw '*Invalid Docker repository*'
            $dockerCalls.Count | Should -Be 0
        }
    }

    Context 'Publication safeguards, conflict prevention, and multi-platform verification' {
        It 'requires an explicit EngineVersion when publishing' {
            { & $buildScript -Publish } | Should -Throw '*Publishing requires an explicit -EngineVersion*'
            $dockerCalls.Count | Should -Be 0
        }

        It 'preserves platform safeguards for local and published builds' {
            { & $buildScript -Platform 'linux/386' } | Should -Throw '*Supported builder platforms are linux/amd64 and linux/arm64*'
            { & $buildScript -Platform 'linux/amd64,linux/arm64' } | Should -Throw '*A local build loads one platform*'
            { & $buildScript -EngineVersion '1.1.0' -Platform 'linux/amd64' -Publish } | Should -Throw "*Specify exactly one platform for 'linux/arm64'*"
            { & $buildScript -EngineVersion '1.1.0' -Platform 'linux/arm64,linux/arm64,linux/amd64' -Publish } | Should -Throw "*Specify exactly one platform for 'linux/arm64'*"
            $dockerCalls.Count | Should -Be 0
        }

        It 'requires a valid Git source revision when publishing' {
            $gitState.ExitCode = 128
            $gitState.Output = 'fatal: not a git repository'

            { & $buildScript -EngineVersion '1.1.0' -Publish } | Should -Throw '*valid Git source revision*'
            $dockerCalls.Count | Should -Be 0
        }

        It 'refuses to reassign an already published engine-qualified tag before building or pushing' {
            $dockerState.PreflightResponses['codebeltnet/docfx:2.81-v1.1.0'] = @{
                ExitCode = 0
                Output   = '{"digest":"sha256:' + ('9' * 64) + '"}'
            }

            { & $buildScript -EngineVersion '1.1.0' -Publish } |
                Should -Throw "*codebeltnet/docfx:2.81-v1.1.0*already exists*sha256:$('9' * 64)*Refusing to reassign*"

            @($dockerCalls | Where-Object { $_[1] -ceq 'build' }).Count | Should -Be 0
        }

        It 'refuses reassignment even when registry inspect returns exit 0 without a digest field' {
            $dockerState.PreflightResponses['codebeltnet/docfx:2.81.0-v1.1.0'] = @{
                ExitCode = 0
                Output   = '{}'
            }

            { & $buildScript -EngineVersion '1.1.0' -Publish } |
                Should -Throw '*codebeltnet/docfx:2.81.0-v1.1.0*already exists in the registry. Refusing to reassign*'
        }

        It 'fails closed on unexpected registry errors during preflight conflict check' {
            $dockerState.PreflightResponses['codebeltnet/docfx:2.81.0-v1.1.0'] = @{
                ExitCode = 1
                Output   = 'ERROR: unauthorized: authentication required'
            }

            { & $buildScript -EngineVersion '1.1.0' -Publish } |
                Should -Throw '*Could not verify whether engine-qualified tag*exit code 1*unauthorized: authentication required*'

            @($dockerCalls | Where-Object { $_[1] -ceq 'build' }).Count | Should -Be 0
        }

        It 'publishes once, checks all seven tags, verifies both platforms and OCI labels, and prints the digest-pinned reference' {
            $dockerState.PreflightResponses['codebeltnet/docfx:2.81.0-v1.1.0'] = @{ ExitCode = 1; Output = 'ERROR: manifest unknown' }
            $dockerState.PreflightResponses['codebeltnet/docfx:2.81-v1.1.0'] = @{ ExitCode = 1; Output = 'ERROR: NAME_UNKNOWN' }
            $dockerState.PreflightResponses['codebeltnet/docfx:2-v1.1.0'] = @{ ExitCode = 1; Output = 'ERROR: not found' }

            $output = & $buildScript -EngineVersion '1.1.0' -Publish

            $output | Should -BeExactly "codebeltnet/docfx:2.81.0-v1.1.0@$validIndexDigest"

            $buildCalls = @($dockerCalls | Where-Object { $_[0] -ceq 'buildx' -and $_[1] -ceq 'build' })
            $buildCalls.Count | Should -Be 1
            $buildArgs = $buildCalls[0]
            $buildArgs | Should -Contain '--push'
            (Get-ArgumentValues $buildArgs '--platform') | Should -Be @('linux/arm64,linux/amd64')
            (Get-ArgumentValues $buildArgs '--tag') | Should -Be @(
                'codebeltnet/docfx:2.81.0-v1.1.0'
                'codebeltnet/docfx:2.81-v1.1.0'
                'codebeltnet/docfx:2-v1.1.0'
                'codebeltnet/docfx:2.81.0'
                'codebeltnet/docfx:2.81'
                'codebeltnet/docfx:2'
                'codebeltnet/docfx:latest'
            )

            $inspectManifestCalls = @($dockerCalls | Where-Object { $_[1] -ceq 'imagetools' -and $_[4] -ceq '{{json .Manifest}}' })
            $inspectManifestCalls.Count | Should -Be 10
            $inspectImageCalls = @($dockerCalls | Where-Object { $_[1] -ceq 'imagetools' -and $_[4] -ceq '{{json .Image}}' })
            $inspectImageCalls.Count | Should -Be 2
        }

        It 'supports publishing without a ContainerRegistry prefix and accepts Docker manifest list mediaType' {
            $dockerState.IndexMediaType = 'application/vnd.docker.distribution.manifest.list.v2+json'

            $output = & $buildScript -ContainerRegistry '' -Tag 'docfx' -EngineVersion '1.1.0' -Publish
            $output | Should -BeExactly "docfx:2.81.0-v1.1.0@$validIndexDigest"
        }

        It 'publishes prerelease engine versions to engine-qualified tags only without moving convenience tags' {
            $dockerState.ImageLabels['org.opencontainers.image.version'] = '1.2.0-rc.1'
            $dockerState.ImageLabels['net.codebelt.docfx.engine.version'] = '1.2.0-rc.1'

            $output = & $buildScript -ContainerRegistry 'localhost:5000/team/' -EngineVersion '1.2.0-rc.1' -Publish
            $output | Should -BeExactly "localhost:5000/team/docfx:2.81.0-v1.2.0-rc.1@$validIndexDigest"

            $buildArgs = @($dockerCalls | Where-Object { $_[0] -ceq 'buildx' -and $_[1] -ceq 'build' })[0]
            (Get-ArgumentValues $buildArgs '--tag') | Should -Be @(
                'localhost:5000/team/docfx:2.81.0-v1.2.0-rc.1'
                'localhost:5000/team/docfx:2.81-v1.2.0-rc.1'
                'localhost:5000/team/docfx:2-v1.2.0-rc.1'
            )
        }

        It 'diagnoses post-publish verification failures for <Scenario>' -ForEach @(
            @{
                Scenario = 'invalid buildx metadata digest'
                Setup    = { $dockerState.BuildDigest = 'not-a-digest' }
                Expected = '*valid published image digest*'
            }
            @{
                Scenario = 'tag resolving to a different index digest'
                Setup    = { $dockerState.IndexDigest = 'sha256:' + ('f' * 64) }
                Expected = '*does not resolve to image index*'
            }
            @{
                Scenario = 'tag resolving to a non-index mediaType'
                Setup    = { $dockerState.IndexMediaType = 'application/vnd.oci.image.manifest.v1+json' }
                Expected = '*does not resolve to image index*'
            }
            @{
                Scenario = 'missing platform manifest in image index'
                Setup    = {
                    $dockerState.Manifests = @($dockerState.Manifests | Where-Object { $_.platform.architecture -cne 'arm64' })
                }
                Expected = "*does not identify one image manifest for 'linux/arm64'*"
            }
            @{
                Scenario = 'mismatched platform OS/architecture in image config'
                Setup    = {
                    $dockerState.ImageResponses["codebeltnet/docfx@$arm64Digest"] = @{
                        ExitCode = 0
                        Output   = (@{ os = 'linux'; architecture = 'amd64'; config = @{ Labels = $dockerState.ImageLabels } } | ConvertTo-Json -Depth 5)
                    }
                }
                Expected = "*Published image config for 'linux/arm64' reports 'linux/amd64'*"
            }
            @{
                Scenario = 'mismatched OCI engine version label in published image config'
                Setup    = {
                    $dockerState.ImageLabels['org.opencontainers.image.version'] = '1.0.1'
                }
                Expected = "*reports label 'org.opencontainers.image.version' as '1.0.1' instead of '1.1.0'*"
            }
            @{
                Scenario = 'missing OCI labels object in published image config'
                Setup    = {
                    $dockerState.ImageLabels = $null
                }
                Expected = "*reports label 'org.opencontainers.image.version' as '' instead of '1.1.0'*"
            }
        ) {
            & $Setup
            { & $buildScript -EngineVersion '1.1.0' -Publish } | Should -Throw $Expected
        }
    }
}
