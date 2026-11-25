BeforeAll {
    $repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot/..").Path
    $modulePath = (Resolve-Path -LiteralPath "$PSScriptRoot/../tools/DocfxImage.psm1").Path
    $releaseScript = (Resolve-Path -LiteralPath "$PSScriptRoot/../tools/Invoke-DocfxRelease.ps1").Path
    Import-Module $modulePath -Force

    if (-not (Get-Command skopeo -ErrorAction SilentlyContinue)) {
        function global:skopeo { $global:LASTEXITCODE = 0 }
        $script:createdSkopeoStub = $true
    } else {
        $script:createdSkopeoStub = $false
    }

    $validRevision = 'a' * 40
    $validIndexDigest = 'sha256:' + ('1' * 64)
    $conflictDigest = 'sha256:' + ('9' * 64)
    $amd64Config = 'sha256:' + ('2' * 64)
    $arm64Config = 'sha256:' + ('3' * 64)
    $validTags = @(
        'codebeltnet/docfx:2.81.0-v1.1.0'
        'codebeltnet/docfx:2.81-v1.1.0'
        'codebeltnet/docfx:2-v1.1.0'
        'codebeltnet/docfx:2.81.0'
        'codebeltnet/docfx:2.81'
        'codebeltnet/docfx:2'
        'codebeltnet/docfx:latest'
    )
    $validEngineTags = $validTags[0..2]
    $validConvenienceTags = $validTags[3..6]
}

AfterAll {
    if ($script:createdSkopeoStub) {
        Remove-Item Function:global:skopeo -ErrorAction SilentlyContinue
    }
}

Describe 'DocfxImage shared module contracts and OCI promotion safeguards' {
    Context 'Version resolution and repository consistency' {
        It 'validates vMAJOR.MINOR.PATCH release tags and rejects invalid tags' {
            Resolve-ReleaseTagVersion -Tag 'v1.1.0' | Should -Be '1.1.0'
            foreach ($bad in @('', '1.1.0', 'v01.1.0', 'v1.1', 'v1.1.0-rc.1', 'latest')) {
                { Resolve-ReleaseTagVersion -Tag $bad } | Should -Throw '*Invalid release tag*'
            }
        }

        It 'verifies repository DocFX version consistency and detects drift' {
            Test-DocfxVersionConsistency -RootPath $repoRoot | Should -Be '2.81.0'

            $missingRoot = Join-Path $TestDrive 'missing-dockerfile'
            New-Item -ItemType Directory -Path $missingRoot -Force | Out-Null
            { Get-DocfxDefaultVersion -RootPath $missingRoot } | Should -Throw '*Authoritative Dockerfile was not found*'

            $driftRoot = Join-Path $TestDrive 'drift'
            New-Item -ItemType Directory -Path "$driftRoot/framework-views", "$driftRoot/templates/ms-style" -Force | Out-Null
            Set-Content -LiteralPath "$driftRoot/Dockerfile" 'FROM scratch'
            { Get-DocfxDefaultVersion -RootPath $driftRoot } | Should -Throw '*Dockerfile does not declare*ARG DOCFX_VERSION*'

            Set-Content -LiteralPath "$driftRoot/Dockerfile" 'ARG DOCFX_VERSION=2.81.0'
            Set-Content -LiteralPath "$driftRoot/framework-views/Build-DocfxFrameworkViews.ps1" '$supportedDocfx = ''2.80.0'''
            Set-Content -LiteralPath "$driftRoot/templates/ms-style/framework-views.compat" 'framework-views-v1/docfx-2.81.0'
            { Test-DocfxVersionConsistency -RootPath $driftRoot } | Should -Throw '*Build-DocfxFrameworkViews.ps1*'

            Set-Content -LiteralPath "$driftRoot/framework-views/Build-DocfxFrameworkViews.ps1" '$supportedDocfx = ''2.81.0'''
            Set-Content -LiteralPath "$driftRoot/templates/ms-style/framework-views.compat" 'framework-views-v1/docfx-2.80.0'
            { Test-DocfxVersionConsistency -RootPath $driftRoot } | Should -Throw '*framework-views.compat*'
        }
    }

    Context 'Native Docker host and Skopeo transport checks' {
        It 'enforces native Docker host architecture without silent emulation' {
            Mock -ModuleName DocfxImage docker { $global:LASTEXITCODE = 0; 'linux/x86_64' }
            { Assert-NativeDockerHost -Platform 'linux/amd64' } | Should -Not -Throw
            { Assert-NativeDockerHost -Platform 'linux/arm64' -DockerContext 'ctx' } | Should -Throw '*Native Docker host required*'

            Mock -ModuleName DocfxImage docker { $global:LASTEXITCODE = 1; 'daemon down' }
            { Assert-NativeDockerHost -Platform 'linux/amd64' } | Should -Throw '*Cannot access native Docker host*'
        }

        It 'selects native Skopeo or local utility container and rejects remote TCP/SSH daemons without native Skopeo' {
            Mock -ModuleName DocfxImage Get-Command { [pscustomobject]@{ Source = '/usr/bin/skopeo' } }
            Test-SkopeoTransport | Should -BeTrue

            $prevHost = $env:DOCKER_HOST
            $prevCtx = $env:DOCKER_CONTEXT
            try {
                Mock -ModuleName DocfxImage Get-Command { $null }
                $env:DOCKER_CONTEXT = ''
                $env:DOCKER_HOST = 'unix:///var/run/docker.sock'
                Test-SkopeoTransport | Should -BeFalse

                $env:DOCKER_HOST = 'ssh://remote-builder'
                { Test-SkopeoTransport } | Should -Throw '*Native Skopeo is required*'

                $env:DOCKER_HOST = ''
                Mock -ModuleName DocfxImage docker { $global:LASTEXITCODE = 0; 'npipe:////./pipe/docker_engine' }
                Test-SkopeoTransport | Should -BeFalse

                $env:DOCKER_CONTEXT = 'local'
                $env:DOCKER_HOST = 'ssh://ignored-when-context-set'
                Test-SkopeoTransport | Should -BeFalse
                $env:DOCKER_CONTEXT = ''
                $env:DOCKER_HOST = ''

                Mock -ModuleName DocfxImage docker { $global:LASTEXITCODE = 1; 'inspect failed' }
                { Test-SkopeoTransport } | Should -Throw '*Unable to inspect active Docker context*'
            } finally {
                $env:DOCKER_HOST = $prevHost
                $env:DOCKER_CONTEXT = $prevCtx
            }
        }

        It 'invokes Skopeo natively and via utility container fallback with auth mount and error propagation' {
            Mock -ModuleName DocfxImage Test-SkopeoTransport { $true }
            Mock -ModuleName DocfxImage skopeo { $global:LASTEXITCODE = 0 }
            { Invoke-Skopeo -Arguments @('copy', 'oci:/tmp/x', 'docker://reg/img:1') } | Should -Not -Throw

            Mock -ModuleName DocfxImage skopeo { $global:LASTEXITCODE = 7 }
            { Invoke-Skopeo -Arguments @('copy', 'oci:/tmp/x', 'docker://reg/img:1') } | Should -Throw '*exited with code 7*'

            $global:DocfxPwshPath = (Get-Command pwsh).Source
            Mock -ModuleName DocfxImage Get-Command { [pscustomobject]@{ Source = $global:DocfxPwshPath } }
            $captured = Invoke-Skopeo -Arguments @('-NoProfile', '-Command', '[Console]::Out.Write("hello-raw")') -CaptureOutput
            [Text.Encoding]::UTF8.GetString($captured) | Should -Be 'hello-raw'

            { Invoke-Skopeo -Arguments @('-NoProfile', '-Command', '[Console]::Error.Write("manifest unknown"); exit 1') -CaptureOutput } |
                Should -Throw '*exited with code 1*manifest unknown*'
            Remove-Variable DocfxPwshPath -Scope Global -ErrorAction SilentlyContinue

            $prevAuth = $env:REGISTRY_AUTH_FILE
            $authFile = Join-Path $TestDrive 'auth.json'
            Set-Content -LiteralPath $authFile '{}'
            $global:DocfxCapturedDockerArgs = $null
            try {
                $env:REGISTRY_AUTH_FILE = $authFile
                Mock -ModuleName DocfxImage Test-SkopeoTransport { $false }
                Mock -ModuleName DocfxImage docker {
                    $global:DocfxCapturedDockerArgs = @($args)
                    $global:LASTEXITCODE = 0
                    '{"schemaVersion":2}'
                }

                $tarFile = Join-Path $TestDrive 'sample.tar'
                Invoke-Skopeo -Arguments @('copy', "oci-archive:$tarFile", "docker-archive:${tarFile}:local:tag")
                ($global:DocfxCapturedDockerArgs -join ' ') | Should -BeLike '*REGISTRY_AUTH_FILE=/auth.json*quay.io/skopeo/stable:v1.20.0*'

                $rawBytes = Invoke-Skopeo -Arguments @('inspect', '--raw', 'docker://reg/img:1') -CaptureOutput
                [Text.Encoding]::UTF8.GetString($rawBytes) | Should -Be '{"schemaVersion":2}'

                Mock -ModuleName DocfxImage docker { $global:LASTEXITCODE = 1; 'unauthorized' }
                { Invoke-Skopeo -Arguments @('inspect', '--raw', 'docker://reg/img:1') -CaptureOutput } |
                    Should -Throw '*exited with code 1*unauthorized*'
            } finally {
                $env:REGISTRY_AUTH_FILE = $prevAuth
                Remove-Variable DocfxCapturedDockerArgs -Scope Global -ErrorAction SilentlyContinue
            }
        }

        It 'wraps Invoke-OciArtifact and handles non-zero failures cleanly' {
            Mock -ModuleName DocfxImage dotnet { $global:LASTEXITCODE = 0; '{"ok":true}' }
            (Invoke-OciArtifact -Arguments @('seal', 'a.tar')) | Should -Be '{"ok":true}'

            Mock -ModuleName DocfxImage dotnet { $global:LASTEXITCODE = 1; 'bad archive' }
            { Invoke-OciArtifact -Arguments @('verify', 'a.tar') } | Should -Throw '*OciArtifact verify failed (exit 1): bad archive*'
        }

        It 'distinguishes missing registry manifests from auth/network/server errors' {
            $global:DocfxRawBytes = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2}')
            $expectedHash = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($global:DocfxRawBytes)).ToLowerInvariant()

            try {
                Mock -ModuleName DocfxImage Invoke-Skopeo { return $global:DocfxRawBytes }
                Get-RegistryManifestDigest -Reference 'codebeltnet/docfx:2.81.0-v1.1.0' | Should -Be $expectedHash

                Mock -ModuleName DocfxImage Invoke-Skopeo { throw 'skopeo inspect exited with code 1: manifest unknown' }
                Get-RegistryManifestDigest -Reference 'codebeltnet/docfx:2.81.0-v1.1.0' | Should -BeNullOrEmpty

                Mock -ModuleName DocfxImage Invoke-Skopeo { throw 'skopeo inspect exited with code 1: unauthorized: authentication required' }
                { Get-RegistryManifestDigest -Reference 'codebeltnet/docfx:2.81.0-v1.1.0' } | Should -Throw '*Could not inspect registry reference*unauthorized*'
            } finally {
                Remove-Variable DocfxRawBytes -Scope Global -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Promotion preflight, conflict prevention, idempotent retry, and stale protection' {
        BeforeEach {
            $archiveFile = Join-Path $TestDrive 'docfx.oci.tar'
            Set-Content -LiteralPath $archiveFile 'archive-bytes'
            $rawIndexBytes = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"manifests":[]}')
            $computedDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawIndexBytes)).ToLowerInvariant()

            $global:DocfxPromoState = @{
                ArchiveFile    = $archiveFile
                RawIndexBytes  = $rawIndexBytes
                ComputedDigest = $computedDigest
                ConflictDigest = $conflictDigest
                Amd64Config    = $amd64Config
                Arm64Config    = $arm64Config
                Registry       = @{}
                Events         = [System.Collections.Generic.List[string]]::new()
                CallNum        = 0
                InspectCount   = 0
            }

            Mock -ModuleName DocfxImage Invoke-OciArtifact {
                param([string[]] $Arguments)
                $s = $global:DocfxPromoState
                switch ($Arguments[0]) {
                    'check-seal' { '{"archiveSha256":"' + ('a' * 64) + '"}' }
                    'verify' { (@{ indexDigest = $s.ComputedDigest; platforms = @('amd64', 'arm64'); configs = @{ amd64 = $s.Amd64Config; arm64 = $s.Arm64Config } } | ConvertTo-Json -Compress) }
                    'extract-layout' {
                        $dir = $Arguments[3]
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                        '{"layoutPath":"' + $dir.Replace('\', '\\') + '"}'
                    }
                }
            }
        }

        AfterEach {
            Remove-Variable DocfxPromoState -Scope Global -ErrorAction SilentlyContinue
        }

        It 'rejects invalid tag sets in preflight' {
            $base = @{
                ArchivePath         = $global:DocfxPromoState.ArchiveFile
                EngineVersion       = '1.1.0'
                DocfxVersion        = '2.81.0'
                Revision            = $validRevision
                Tags                = $validTags
                EngineQualifiedTags = $validEngineTags
            }
            { Test-DocfxPromotionPreflight @base -Tags @() } | Should -Throw '*at least one destination tag*'
            { Test-DocfxPromotionPreflight @base -EngineQualifiedTags @() } | Should -Throw '*explicit engine-qualified*'
            { Test-DocfxPromotionPreflight @base -Tags @($validTags[0], $validTags[0]) } | Should -Throw '*must be unique*'
            { Test-DocfxPromotionPreflight @base -Tags @('codebeltnet/docfx:2-v1.1.0', 'other/docfx:2') } | Should -Throw '*target one repository*'
            $portQualifiedEngineTag = 'localhost:5000/team/docfx:2-v1.1.0'
            {
                Test-DocfxPromotionPreflight @base -Tags @($portQualifiedEngineTag, 'localhost:5000/other/docfx:2') -EngineQualifiedTags @($portQualifiedEngineTag)
            } | Should -Throw '*target one repository*'
            { Test-DocfxPromotionPreflight @base -EngineQualifiedTags @('codebeltnet/docfx:9-v1.1.0') } | Should -Throw '*must be included in destination tags*'
            { Test-DocfxPromotionPreflight @base -Tags @('codebeltnet/docfx:2-v1.0.0') -EngineQualifiedTags @('codebeltnet/docfx:2-v1.0.0') } | Should -Throw '*does not match engine version*'
        }

        It 'rejects conflicting engine-qualified tag digest and accepts matching digest for idempotent retry' {
            Mock -ModuleName DocfxImage Get-RegistryManifestDigest {
                param($Reference)
                if ($Reference -ceq 'codebeltnet/docfx:2.81-v1.1.0') { return $global:DocfxPromoState.ConflictDigest }
                return $null
            }
            {
                Test-DocfxPromotionPreflight -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                    -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags -Platform 'amd64' -ExpectedIndexDigest $global:DocfxPromoState.ComputedDigest
            } | Should -Throw '*Engine-qualified tag conflict*Refusing to overwrite*'

            Mock -ModuleName DocfxImage Get-RegistryManifestDigest { return $null }
            {
                Test-DocfxPromotionPreflight -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                    -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags -RequireEngineTagsPresent
            } | Should -Throw '*is absent in the registry before convenience tag promotion*'

            Mock -ModuleName DocfxImage Get-RegistryManifestDigest { return $global:DocfxPromoState.ComputedDigest }
            $res = Test-DocfxPromotionPreflight -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags -RequireEngineTagsPresent
            $res.IndexDigest | Should -Be $global:DocfxPromoState.ComputedDigest
        }

        It 'promotes engine-qualified tags first and verifies <Repository> by digest' -ForEach @(
            @{ Repository = 'codebeltnet/docfx' }
            @{ Repository = 'localhost:5000/team/docfx' }
        ) {
            $tags = @($validTags | ForEach-Object { $_.Replace('codebeltnet/docfx', $Repository) })
            $engineTags = $tags[0..2]
            $global:DocfxPromoState.Registry["${Repository}:2.81.0-v1.1.0"] = $global:DocfxPromoState.ComputedDigest

            Mock -ModuleName DocfxImage Get-RegistryManifestDigest {
                param($Reference)
                if ($global:DocfxPromoState.Registry.ContainsKey($Reference)) { return $global:DocfxPromoState.Registry[$Reference] }
                return $null
            }
            Mock -ModuleName DocfxImage Invoke-Skopeo {
                param([string[]] $Arguments, [switch] $CaptureOutput)
                $s = $global:DocfxPromoState
                if ($Arguments[0] -ceq 'inspect') { return $s.RawIndexBytes }
                if ($Arguments[3].StartsWith('docker://')) {
                    $s.Events.Add("verify-download:$($Arguments[3])")
                    return
                }
                $dest = $Arguments[-1].Substring('docker://'.Length)
                $s.Registry[$dest] = $s.ComputedDigest
                $s.Events.Add("push:$dest")
            }

            $summaryPath = Join-Path $TestDrive 'summary.md'
            $prevSummary = $env:GITHUB_STEP_SUMMARY
            try {
                $env:GITHUB_STEP_SUMMARY = $summaryPath
                $result = Publish-DocfxOciArchive `
                    -ArchivePath $global:DocfxPromoState.ArchiveFile `
                    -EngineVersion '1.1.0' `
                    -DocfxVersion '2.81.0' `
                    -Revision $validRevision `
                    -Tags $tags `
                    -EngineQualifiedTags $engineTags `
                    -ExpectedIndexDigest $global:DocfxPromoState.ComputedDigest `
                    -Platform 'amd64' `
                    -BeforeConvenience { $global:DocfxPromoState.Events.Add('before-convenience') }
            } finally {
                $env:GITHUB_STEP_SUMMARY = $prevSummary
            }

            $result.Published.Count | Should -Be 7
            $global:DocfxPromoState.Events | Should -Be @(
                "push:${Repository}:2.81-v1.1.0"
                "push:${Repository}:2-v1.1.0"
                'before-convenience'
                "push:${Repository}:2.81.0"
                "push:${Repository}:2.81"
                "push:${Repository}:2"
                "push:${Repository}:latest"
                "verify-download:docker://$Repository@$($global:DocfxPromoState.ComputedDigest)"
            )
            Test-Path -LiteralPath "$($global:DocfxPromoState.ArchiveFile).published.json" | Should -BeTrue
            (Get-Content -LiteralPath $summaryPath -Raw) | Should -BeLike "*$($global:DocfxPromoState.ComputedDigest)*"
        }

        It 'fails when concurrent conflict occurs on recheck or when registry rewrites index digest' {
            Mock -ModuleName DocfxImage Get-RegistryManifestDigest {
                $global:DocfxPromoState.CallNum++
                if ($global:DocfxPromoState.CallNum -le 3) { return $null }
                return $global:DocfxPromoState.ConflictDigest
            }
            {
                Publish-DocfxOciArchive -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                    -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags
            } | Should -Throw '*Engine-qualified tag conflict*Refusing to overwrite*'

            Mock -ModuleName DocfxImage Get-RegistryManifestDigest { return $null }
            Mock -ModuleName DocfxImage Invoke-Skopeo {
                param([string[]] $Arguments, [switch] $CaptureOutput)
                if ($Arguments[0] -ceq 'inspect') { return [Text.Encoding]::UTF8.GetBytes('rewritten-bytes') }
            }
            {
                Publish-DocfxOciArchive -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                    -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags
            } | Should -Throw '*Registry OCI index digest changed*'

            Mock -ModuleName DocfxImage Get-RegistryManifestDigest { return $global:DocfxPromoState.ComputedDigest }
            Mock -ModuleName DocfxImage Invoke-Skopeo {
                param([string[]] $Arguments, [switch] $CaptureOutput)
                if ($Arguments[0] -ceq 'inspect') {
                    $global:DocfxPromoState.InspectCount++
                    if ($global:DocfxPromoState.InspectCount -le 3) { return $global:DocfxPromoState.RawIndexBytes }
                    return [Text.Encoding]::UTF8.GetBytes('rewritten-convenience')
                }
            }
            {
                Publish-DocfxOciArchive -ArchivePath $global:DocfxPromoState.ArchiveFile -EngineVersion '1.1.0' -DocfxVersion '2.81.0' `
                    -Revision $validRevision -Tags $validTags -EngineQualifiedTags $validEngineTags
            } | Should -Throw '*Registry OCI index digest changed*'
        }
    }
}

Describe 'Invoke-DocfxRelease CI/CD lifecycle orchestration' {
    BeforeEach {
        $script:savedEnv = @{
            GITHUB_REF_NAME     = $env:GITHUB_REF_NAME
            GITHUB_SHA          = $env:GITHUB_SHA
            GITHUB_REPOSITORY   = $env:GITHUB_REPOSITORY
            GITHUB_EVENT_NAME   = $env:GITHUB_EVENT_NAME
            GITHUB_EVENT_PATH   = $env:GITHUB_EVENT_PATH
            GITHUB_REF          = $env:GITHUB_REF
            GITHUB_RUN_ID       = $env:GITHUB_RUN_ID
            GITHUB_RUN_ATTEMPT  = $env:GITHUB_RUN_ATTEMPT
            GITHUB_OUTPUT       = $env:GITHUB_OUTPUT
            GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY
            RELEASE_TAG         = $env:RELEASE_TAG
        }
        $script:work = Join-Path $TestDrive ('rel-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:work -Force | Out-Null
        $env:GITHUB_REPOSITORY = 'codebeltnet/docfx'
        $env:GITHUB_REF_NAME = 'v1.1.0'
        $env:RELEASE_TAG = 'v1.1.0'
        $env:GITHUB_SHA = $validRevision
        $env:GITHUB_RUN_ID = '9001'
        $env:GITHUB_RUN_ATTEMPT = '1'
        $env:GITHUB_OUTPUT = Join-Path $script:work 'github-output.txt'
        $env:GITHUB_STEP_SUMMARY = Join-Path $script:work 'github-summary.md'

        $global:DocfxRelTestState = @{
            GhMap = @{}
        }
    }

    AfterEach {
        foreach ($key in $script:savedEnv.Keys) {
            if ($null -eq $script:savedEnv[$key]) { Remove-Item "Env:$key" -ErrorAction SilentlyContinue }
            else { Set-Item "Env:$key" -Value $script:savedEnv[$key] }
        }
        Remove-Item Function:global:gh -ErrorAction SilentlyContinue
        Remove-Variable DocfxRelTestState -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'ValidateTag' {
        It 'validates tag, revision, and version consistency and emits GitHub outputs' {
            Mock Get-DocfxSourceRevision { return ('a' * 40) }
            $out = & $releaseScript -Command ValidateTag
            $out | Should -BeLike '*Validated release tag v1.1.0*'
            (Get-Content -LiteralPath $env:GITHUB_OUTPUT -Raw) | Should -BeLike '*engine-version=1.1.0*docfx-version=2.81.0*'

            $env:GITHUB_SHA = 'b' * 40
            { & $releaseScript -Command ValidateTag } | Should -Throw '*does not match GITHUB_SHA*'
        }
    }

    Context 'Assemble, Split, and VerifyDraftAssets' {
        BeforeEach {
            $script:inputsDir = Join-Path $script:work 'inputs'
            $script:outDir = Join-Path $script:work 'out'
            $script:assetsDir = Join-Path $script:work 'assets'
            foreach ($cpu in 'amd64', 'arm64') {
                $dir = Join-Path $script:inputsDir "container-$cpu"
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                $archivePath = Join-Path $dir "docfx.$cpu.oci.tar"
                Set-Content -LiteralPath $archivePath "archive-$cpu"
                $cfg = if ($cpu -ceq 'amd64') { $amd64Config } else { $arm64Config }
                @{
                    DocfxVersion        = '2.81.0'
                    EngineVersion       = '1.1.0'
                    Repository          = 'codebeltnet/docfx'
                    SourceRepository    = 'https://github.com/codebeltnet/docfx'
                    SourceCommit        = $validRevision
                    Platform            = "linux/$cpu"
                    Architecture        = $cpu
                    Tags                = $validTags
                    ConvenienceTags     = $validConvenienceTags
                    EngineQualifiedTags = $validEngineTags
                    ConfigDigest        = $cfg
                    SizeBytes           = 1000
                    ArchiveSha256       = (Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
                    OciArchiveBytes     = (Get-Item -LiteralPath $archivePath).Length
                    NativeVerified      = $true
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'docfx-image.json')
            }

            Mock Invoke-OciArtifact {
                param([string[]] $Arguments)
                switch ($Arguments[0]) {
                    'verify' {
                        $cpu = $Arguments[[Array]::IndexOf($Arguments, '--platform') + 1]
                        $cfg = if ($cpu -ceq 'amd64') { 'sha256:' + ('2' * 64) } else { 'sha256:' + ('3' * 64) }
                        $hash = (Get-FileHash -LiteralPath $Arguments[1]).Hash.ToLowerInvariant()
                        (@{ indexDigest = 'sha256:' + ('1' * 64); archiveSha256 = $hash; platforms = @($cpu); configs = @{ $cpu = $cfg } } | ConvertTo-Json -Compress)
                    }
                    'merge' {
                        Set-Content -LiteralPath $Arguments[1] 'merged-oci-tar'
                        (@{ indexDigest = 'sha256:' + ('1' * 64); archiveSha256 = ('f' * 64); archiveBytes = 14; platforms = @('amd64', 'arm64') } | ConvertTo-Json -Compress)
                    }
                    'split' {
                        $outDirArg = $Arguments[[Array]::IndexOf($Arguments, '--output-dir') + 1]
                        Set-Content -LiteralPath (Join-Path $outDirArg 'docfx.oci.part000') 'part-zero'
                        Set-Content -LiteralPath (Join-Path $outDirArg 'docfx.oci.tar.sha256') (('f' * 64) + '  docfx.oci.tar')
                        (@{ archiveSha256 = ('f' * 64); archiveBytes = 14; pieces = @(@{ name = 'docfx.oci.part000'; sha256 = ('d' * 64); size = 9 }) } | ConvertTo-Json -Compress)
                    }
                }
            }
        }

        It 'assembles both native verified archives, writes release.json, splits assets, and verifies draft assets' {
            $out = & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir
            $out | Should -BeLike "*Assembled multi-platform OCI index $validIndexDigest*"
            Test-Path -LiteralPath (Join-Path $script:outDir 'release.json') | Should -BeTrue
            Test-Path -LiteralPath $env:GITHUB_STEP_SUMMARY | Should -BeTrue

            $splitOut = & $releaseScript -Command Split -OutDir $script:outDir -AssetsDir $script:assetsDir
            $splitOut | Should -BeLike '*Prepared 1 release asset piece*'
            Test-Path -LiteralPath (Join-Path $script:assetsDir 'docfx-release.json') | Should -BeTrue

            { & $releaseScript -Command Split -OutDir (Join-Path $script:work 'empty-out') -AssetsDir $script:assetsDir } | Should -Throw '*Expected assembled archive*'

            $files = Get-ChildItem -LiteralPath $script:assetsDir -File
            $remoteAssets = @(foreach ($f in $files) {
                @{
                    name   = $f.Name
                    size   = $f.Length
                    digest = 'sha256:' + (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            })
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases?per_page=30'] = @(@{ tag_name = 'v1.1.0'; draft = $true; assets = $remoteAssets })
            function global:gh {
                $endpoint = $args[1]
                if ($global:DocfxRelTestState.GhMap.ContainsKey($endpoint)) {
                    $global:LASTEXITCODE = 0
                    return (ConvertTo-Json -InputObject $global:DocfxRelTestState.GhMap[$endpoint] -Depth 10)
                }
                $global:LASTEXITCODE = 1
                return 'not found'
            }

            $vOut = & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir
            $vOut | Should -BeLike '*Verified 3 durable asset*'

            $emptyRel = Join-Path $script:work 'empty-rel'
            New-Item -ItemType Directory -Path $emptyRel -Force | Out-Null
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $emptyRel } | Should -Throw '*No release asset files*'

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases?per_page=30'] = @()
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir } | Should -Throw '*Expected exactly one draft*'

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases?per_page=30'] = @(@{ tag_name = 'v1.1.0'; draft = $true; assets = @($remoteAssets[0]) })
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir } | Should -Throw '*missing expected asset*'

            $badSize = @($remoteAssets | ForEach-Object { $_.Clone() })
            $badSize[0].size = 999999
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases?per_page=30'] = @(@{ tag_name = 'v1.1.0'; draft = $true; assets = $badSize })
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir } | Should -Throw '*size mismatch*'

            $badDigest = @($remoteAssets | ForEach-Object { $_.Clone() })
            $badDigest[0].digest = 'sha256:' + ('0' * 64)
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases?per_page=30'] = @(@{ tag_name = 'v1.1.0'; draft = $true; assets = $badDigest })
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir } | Should -Throw '*digest mismatch*'

            $global:DocfxRelTestState.GhMap.Clear()
            { & $releaseScript -Command VerifyDraftAssets -ReleaseDir $script:assetsDir } | Should -Throw '*gh api*exited with code 1*'
        }

        It 'rejects a native record with a mismatched <Field> before merging' -ForEach @(
            @{ Field = 'ArchiveSha256'; Value = '0' * 64; Expected = '*arm64*OCI archive SHA-256*' }
            @{ Field = 'OciArchiveBytes'; Value = 500; Expected = '*arm64*OCI archive size*' }
        ) {
            $recordPath = Join-Path $script:inputsDir 'container-arm64/docfx-image.json'
            $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
            $record[$Field] = $Value
            $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $recordPath

            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw $Expected
            Should -Invoke Invoke-OciArtifact -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'merge' }
        }

        It 'rejects assembly failures (missing records, unverified, identity/tag/platform/archive/config mismatches)' {
            $amdMetaPath = Join-Path $script:inputsDir 'container-amd64/docfx-image.json'
            $m = Get-Content -LiteralPath $amdMetaPath -Raw | ConvertFrom-Json -AsHashtable
            $m.NativeVerified = $false
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*is not verified*'

            $m.NativeVerified = $true
            $m.EngineVersion = '1.0.9'
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*identity mismatch*'

            $m.EngineVersion = '1.1.0'
            $m.Tags = @('codebeltnet/docfx:other')
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*tag mismatch*'

            $m.Tags = $validTags
            $m.Platform = 'linux/arm64'
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*Both native CPUs*'

            $m.Platform = 'linux/amd64'
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            $env:GITHUB_SHA = 'b' * 40
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*does not match native verification records*'
            $env:GITHUB_SHA = $validRevision

            foreach ($cpu in 'amd64', 'arm64') {
                $p = Join-Path $script:inputsDir "container-$cpu/docfx-image.json"
                $x = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable
                $x.Tags = @('codebeltnet/docfx:wrong')
                $x | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p
            }
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*differs from authoritative BuildAndPushDocfxImage*'
            foreach ($cpu in 'amd64', 'arm64') {
                $p = Join-Path $script:inputsDir "container-$cpu/docfx-image.json"
                $x = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -AsHashtable
                $x.Tags = $validTags
                $x | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $p
            }

            $m.ConfigDigest = 'sha256:' + ('0' * 64)
            $m | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $amdMetaPath
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*does not match the assembled OCI image config digest*'

            Remove-Item -LiteralPath (Join-Path $script:inputsDir 'container-arm64/docfx.arm64.oci.tar')
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*Exactly two native OCI archives*'

            Remove-Item -LiteralPath (Join-Path $script:inputsDir 'container-arm64/docfx-image.json')
            { & $releaseScript -Command Assemble -InputsDir $script:inputsDir -OutDir $script:outDir } | Should -Throw '*Both native verification records*'
        }
    }

    Context 'Resolve, Restore, and Publish (including stale-release protection and recovery)' {
        BeforeEach {
            $script:resolvedDir = Join-Path $script:work 'resolved'
            $script:outDir = Join-Path $script:work 'out'
            $script:assetStore = Join-Path $script:work 'remote-assets'
            New-Item -ItemType Directory -Path $script:assetStore -Force | Out-Null

            $partContent = 'part-zero-bytes'
            $partFile = Join-Path $script:assetStore 'docfx.oci.part000'
            Set-Content -LiteralPath $partFile $partContent -NoNewline
            $partHash = (Get-FileHash -LiteralPath $partFile -Algorithm SHA256).Hash.ToLowerInvariant()
            $partSize = (Get-Item -LiteralPath $partFile).Length

            $checksumFile = Join-Path $script:assetStore 'docfx.oci.tar.sha256'
            Set-Content -LiteralPath $checksumFile "$partHash  docfx.oci.tar`n" -NoNewline
            $checksumHash = (Get-FileHash -LiteralPath $checksumFile -Algorithm SHA256).Hash.ToLowerInvariant()
            $checksumSize = (Get-Item -LiteralPath $checksumFile).Length

            $script:releaseMetaObj = @{
                ReleaseTag          = 'v1.1.0'
                DocfxVersion        = '2.81.0'
                EngineVersion       = '1.1.0'
                SourceCommit        = $validRevision
                SourceRepository    = 'https://github.com/codebeltnet/docfx'
                Repository          = 'codebeltnet/docfx'
                Tags                = $validTags
                ConvenienceTags     = $validConvenienceTags
                EngineQualifiedTags = $validEngineTags
                OciIndexDigest      = $validIndexDigest
                ArchiveSha256       = $partHash
                ArchiveBytes        = $partSize
                ReleaseRunId        = '9001'
                ReleaseRunAttempt   = '1'
                Pieces              = @(@{ Name = 'docfx.oci.part000'; Sha256 = $partHash; Size = $partSize })
                Verification        = @(
                    @{ Platform = 'linux/amd64'; Architecture = 'amd64'; NativeVerified = $true; DocfxVersion = '2.81.0'; EngineVersion = '1.1.0'; SourceCommit = $validRevision; Tags = $validTags; ConvenienceTags = $validConvenienceTags; EngineQualifiedTags = $validEngineTags; SizeBytes = 1000; OciArchiveBytes = 500 }
                    @{ Platform = 'linux/arm64'; Architecture = 'arm64'; NativeVerified = $true; DocfxVersion = '2.81.0'; EngineVersion = '1.1.0'; SourceCommit = $validRevision; Tags = $validTags; ConvenienceTags = $validConvenienceTags; EngineQualifiedTags = $validEngineTags; SizeBytes = 1000; OciArchiveBytes = 500 }
                )
            }
            $relJsonFile = Join-Path $script:assetStore 'docfx-release.json'
            $script:releaseMetaObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $relJsonFile -NoNewline
            $relJsonHash = (Get-FileHash -LiteralPath $relJsonFile -Algorithm SHA256).Hash.ToLowerInvariant()
            $relJsonSize = (Get-Item -LiteralPath $relJsonFile).Length

            $script:releaseAssets = @(
                @{ name = 'docfx-release.json'; size = $relJsonSize; digest = "sha256:$relJsonHash"; browser_download_url = $relJsonFile }
                @{ name = 'docfx.oci.tar.sha256'; size = $checksumSize; digest = "sha256:$checksumHash"; browser_download_url = $checksumFile }
                @{ name = 'docfx.oci.part000'; size = $partSize; digest = "sha256:$partHash"; browser_download_url = $partFile }
            )

            $global:DocfxRelTestState.GhMap = @{
                'repos/codebeltnet/docfx/releases/tags/v1.1.0'            = @{ id = 42; tag_name = 'v1.1.0'; draft = $false; prerelease = $false; published_at = '2026-11-25T12:00:00Z'; assets = $script:releaseAssets }
                'repos/codebeltnet/docfx/releases/latest'                 = @{ id = 42; tag_name = 'v1.1.0'; draft = $false; prerelease = $false; published_at = '2026-11-25T12:00:00Z' }
                'repos/codebeltnet/docfx/commits/v1.1.0'                  = @{ sha = $validRevision }
                "repos/codebeltnet/docfx/compare/$validRevision...main"   = @{ status = 'identical' }
                'repos/codebeltnet/docfx/actions/runs/9001/attempts/1'    = @{ event = 'push'; path = '.github/workflows/release.yml'; head_sha = $validRevision; head_branch = 'v1.1.0'; run_attempt = 1; conclusion = 'success' }
            }

            function global:gh {
                $endpoint = $args[1]
                if ($global:DocfxRelTestState.GhMap.ContainsKey($endpoint)) {
                    $global:LASTEXITCODE = 0
                    return (ConvertTo-Json -InputObject $global:DocfxRelTestState.GhMap[$endpoint] -Depth 12)
                }
                $global:LASTEXITCODE = 1
                return "unexpected endpoint: $endpoint"
            }

            Mock Invoke-WebRequest {
                param($Uri, $OutFile)
                $sourcePath = if ($Uri -is [uri] -and $Uri.IsFile) { $Uri.LocalPath } else { [string]$Uri }
                Copy-Item -LiteralPath $sourcePath -Destination $OutFile -Force
            }
        }

        It 'resolves published release event and workflow_dispatch from main, and rejects drafts, older releases, non-main branches, and bad ancestry' {
            $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
            $env:GITHUB_REF = 'refs/heads/main'
            $resOut = & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir
            $resOut | Should -BeLike '*Resolved latest published release v1.1.0*'

            $eventFile = Join-Path $script:work 'event.json'
            @{ action = 'published'; release = @{ id = 42; tag_name = 'v1.1.0' } } | ConvertTo-Json | Set-Content -LiteralPath $eventFile
            $env:GITHUB_EVENT_NAME = 'release'
            $env:GITHUB_EVENT_PATH = $eventFile
            & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir | Should -BeLike '*Resolved latest published release*'

            @{ action = 'published'; release = @{ id = 999; tag_name = 'v1.1.0' } } | ConvertTo-Json | Set-Content -LiteralPath $eventFile
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*Published release ID changed*'

            @{ action = 'created'; release = @{ id = 42; tag_name = 'v1.1.0' } } | ConvertTo-Json | Set-Content -LiteralPath $eventFile
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*Unexpected release event payload*'

            $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
            $env:GITHUB_REPOSITORY = 'fork/docfx'
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*restricted to*codebeltnet/docfx*'
            $env:GITHUB_REPOSITORY = 'codebeltnet/docfx'

            $env:GITHUB_REF = 'refs/heads/feature'
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*dispatched from*refs/heads/main*'
            $env:GITHUB_REF = 'refs/heads/main'

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases/latest'] = @{ id = 99; tag_name = 'v1.2.0'; draft = $false; prerelease = $false }
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*latest published stable release*'
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases/latest'] = @{ id = 42; tag_name = 'v1.1.0'; draft = $false; prerelease = $false }

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/commits/v1.1.0'] = @{ sha = 'invalid' }
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*Unable to resolve commit SHA*'
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/commits/v1.1.0'] = @{ sha = $validRevision }

            $global:DocfxRelTestState.GhMap["repos/codebeltnet/docfx/compare/$validRevision...main"] = @{ status = 'diverged' }
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*not in main branch history*'
            $global:DocfxRelTestState.GhMap["repos/codebeltnet/docfx/compare/$validRevision...main"] = @{ status = 'identical' }

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases/tags/v1.1.0'].assets = @()
            { & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir } | Should -Throw '*missing required durable asset*'
        }

        It 'restores and verifies release assets and rejects invalid runs, identities, pieces, or asset checksums' {
            $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
            $env:GITHUB_REF = 'refs/heads/main'
            $null = & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir

            Mock Invoke-OciArtifact {
                param([string[]] $Arguments)
                if ($Arguments[0] -ceq 'reassemble') {
                    $outPath = $Arguments[[Array]::IndexOf($Arguments, '--output') + 1]
                    Set-Content -LiteralPath $outPath 'rebuilt-archive'
                    return '{"archiveSha256":"' + ('a' * 64) + '","archiveBytes":15}'
                }
                return (@{ indexDigest = 'sha256:' + ('1' * 64); platforms = @('amd64', 'arm64') } | ConvertTo-Json -Compress)
            }

            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Not -Throw

            { & $releaseScript -Command Restore -ResolvedDir (Join-Path $script:work 'no-resolved') -OutDir $script:outDir } | Should -Throw '*identity file is missing*'

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/actions/runs/9001/attempts/1'].conclusion = 'failure'
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*Authoritative tag release workflow run did not succeed*'
            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/actions/runs/9001/attempts/1'].conclusion = 'success'

            $idPath = Join-Path $script:resolvedDir 'identity.json'
            $idObj = Get-Content -LiteralPath $idPath -Raw | ConvertFrom-Json -AsHashtable
            $origDigest = $idObj.assets['docfx-release.json'].digest
            $idObj.assets['docfx-release.json'].digest = ''
            $idObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $idPath
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*no authoritative SHA-256 digest*'

            $idObj.assets['docfx-release.json'].digest = $origDigest
            $origUrl = $idObj.assets['docfx-release.json'].browser_download_url
            $idObj.assets['docfx-release.json'].browser_download_url = ''
            $idObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $idPath
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*no download URL*'

            $idObj.assets['docfx-release.json'].browser_download_url = $origUrl
            $idObj.assets['docfx-release.json'].digest = 'sha256:' + ('0' * 64)
            $idObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $idPath
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*checksum or size mismatch*'
            $idObj.assets['docfx-release.json'].digest = $origDigest
            $idObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $idPath

            function Update-ReleaseMeta([scriptblock] $Mutate) {
                $copy = $script:releaseMetaObj | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
                & $Mutate $copy
                $relFile = Join-Path $script:assetStore 'docfx-release.json'
                $copy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $relFile -NoNewline
                $idObj.assets['docfx-release.json'].digest = 'sha256:' + (Get-FileHash -LiteralPath $relFile -Algorithm SHA256).Hash.ToLowerInvariant()
                $idObj.assets['docfx-release.json'].size = (Get-Item -LiteralPath $relFile).Length
                $idObj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $idPath
            }

            Update-ReleaseMeta { param($c) $c.EngineVersion = '1.0.9' }
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*does not match the resolved published release identity*'

            Update-ReleaseMeta { param($c) $c.Verification = @($c.Verification[0]) }
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*Both native architecture verification records*'

            Update-ReleaseMeta { param($c) $c.Verification[0].NativeVerified = $false }
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*Native verification record identity mismatch*'

            Update-ReleaseMeta { param($c) $c.Pieces = @(@{ Name = '../escape.tar'; Sha256 = ('a' * 64); Size = 10 }) }
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*Invalid release archive piece name*'

            Update-ReleaseMeta { param($c) $c.Pieces = @(@{ Name = 'docfx.oci.part999'; Sha256 = ('a' * 64); Size = 10 }) }
            { & $releaseScript -Command Restore -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*missing archive piece*'
        }

        It 'publishes via Publish-DocfxOciArchive and blocks promotion if latest release changes' {
            $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
            $env:GITHUB_REF = 'refs/heads/main'
            $null = & $releaseScript -Command Resolve -ResolvedDir $script:resolvedDir

            Mock Invoke-OciArtifact {
                param([string[]] $Arguments)
                if ($Arguments[0] -ceq 'reassemble') {
                    $outPath = $Arguments[[Array]::IndexOf($Arguments, '--output') + 1]
                    Set-Content -LiteralPath $outPath 'rebuilt-archive'
                    return '{"archiveSha256":"' + ('a' * 64) + '","archiveBytes":15}'
                }
                return (@{ indexDigest = 'sha256:' + ('1' * 64); platforms = @('amd64', 'arm64') } | ConvertTo-Json -Compress)
            }
            Mock Publish-DocfxOciArchive {
                param([scriptblock] $BeforeConvenience)
                if ($BeforeConvenience) { & $BeforeConvenience }
                [pscustomobject]@{
                    IndexDigest = 'sha256:' + ('1' * 64)
                    Repository  = 'codebeltnet/docfx'
                    Published   = @('1','2','3','4','5','6','7' | ForEach-Object { @{ tag = "t$_"; digest = 'sha256:' + ('1' * 64) } })
                }
            }

            $pubOut = & $releaseScript -Command Publish -ResolvedDir $script:resolvedDir -OutDir $script:outDir
            $pubOut | Should -BeLike "*Promoted 7 tags to codebeltnet/docfx@$validIndexDigest*"

            { & $releaseScript -Command Publish -ResolvedDir (Join-Path $script:work 'no-resolved') -OutDir $script:outDir } | Should -Throw '*identity file is missing*'

            $global:DocfxRelTestState.GhMap['repos/codebeltnet/docfx/releases/latest'] = @{ id = 99; tag_name = 'v1.2.0'; draft = $false; prerelease = $false }
            { & $releaseScript -Command Publish -ResolvedDir $script:resolvedDir -OutDir $script:outDir } | Should -Throw '*Latest published release changed*refusing stale*'
        }
    }
}
