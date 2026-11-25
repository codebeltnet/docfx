BeforeAll {
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $ociTool = Join-Path $repoRoot 'tools/OciArtifact.cs'
    $validRevision = 'a' * 40
    $validVersion = '1.1.0'
    $validDocfx = '2.81.0'
    $defaultSource = 'https://github.com/codebeltnet/docfx'

    function Invoke-OciTool {
        param([string[]] $Arguments)
        $output = & dotnet run --file $ociTool -- @Arguments 2>&1
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = (@($output | ForEach-Object { $_.ToString() }) -join "`n").Trim()
        }
    }

    function New-SyntheticOciArchive {
        param(
            [Parameter(Mandatory)][string] $Path,
            [Parameter(Mandatory)][string] $Cpu,
            [string] $Version = $validVersion,
            [string] $DocfxVersion = $validDocfx,
            [string] $Revision = $validRevision,
            [string] $Source = $defaultSource,
            [string] $Created = '2026-11-25T12:00:00Z',
            [string] $MissingPredicate,
            [string] $SubjectOverride,
            [switch] $EmptySubject,
            [string] $ProvenanceDocfxVersion,
            [switch] $UseSlsaV1,
            [switch] $WrapLayoutIndex,
            [switch] $ExtraWindowsPlatform,
            [switch] $EmptySbom,
            [switch] $Seal
        )

        $blobs = [ordered]@{}
        function Add-JsonBlob([hashtable] $Obj, [string] $MediaType = 'application/vnd.oci.image.manifest.v1+json') {
            $json = ConvertTo-Json -InputObject $Obj -Depth 20 -Compress
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
            $hex = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            $blobs["blobs/sha256/$hex"] = $bytes
            @{ digest = "sha256:$hex"; size = $bytes.Length; mediaType = $MediaType }
        }

        $layerBytes = [Text.UTF8Encoding]::new($false).GetBytes("synthetic-layer-$Cpu")
        $layerHex = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($layerBytes)).ToLowerInvariant()
        $blobs["blobs/sha256/$layerHex"] = $layerBytes
        $layerDesc = @{ digest = "sha256:$layerHex"; size = $layerBytes.Length; mediaType = 'application/vnd.oci.image.layer.v1.tar+gzip' }

        $labels = [ordered]@{
            'org.opencontainers.image.source'   = $Source
            'org.opencontainers.image.version'  = $Version
            'org.opencontainers.image.revision' = $Revision
            'net.codebelt.docfx.engine.version' = $Version
            'net.codebelt.docfx.cli.version'    = $DocfxVersion
        }
        if ($Created) { $labels['org.opencontainers.image.created'] = $Created }

        $configDesc = Add-JsonBlob @{
            architecture = $Cpu
            os           = 'linux'
            config       = @{ Labels = $labels }
        } 'application/vnd.oci.image.config.v1+json'

        $imageDesc = Add-JsonBlob @{
            schemaVersion = 2
            mediaType     = 'application/vnd.oci.image.manifest.v1+json'
            config        = $configDesc
            layers        = @($layerDesc)
        }
        $imageDesc['platform'] = @{ os = 'linux'; architecture = $Cpu }

        $attLayers = [System.Collections.Generic.List[hashtable]]::new()
        $provDocfx = if ($ProvenanceDocfxVersion) { $ProvenanceDocfxVersion } else { $DocfxVersion }
        $provArgs = @{
            'build-arg:DOCFX_VERSION'                 = $provDocfx
            'label:org.opencontainers.image.version'  = $Version
            'label:net.codebelt.docfx.engine.version' = $Version
            'label:net.codebelt.docfx.cli.version'    = $DocfxVersion
            'label:org.opencontainers.image.revision' = $Revision
            'label:org.opencontainers.image.source'   = $Source
        }
        $slsaPredicate = if ($UseSlsaV1) {
            @{
                predicateType = 'https://slsa.dev/provenance/v1'
                body          = @{
                    buildDefinition = @{
                        buildType          = 'https://mobyproject.org/buildkit@v1'
                        externalParameters = @{ request = @{ args = $provArgs } }
                    }
                }
            }
        } else {
            @{
                predicateType = 'https://slsa.dev/provenance/v0.2'
                body          = @{
                    buildType  = 'https://mobyproject.org/buildkit@v1'
                    invocation = @{ parameters = @{ args = $provArgs } }
                }
            }
        }
        $sbomPackages = [System.Collections.Generic.List[hashtable]]::new()
        if (-not $EmptySbom) { $sbomPackages.Add(@{ name = 'docfx' }) }
        $sbomBody = @{ spdxVersion = 'SPDX-2.3'; packages = @($sbomPackages.ToArray()) }

        foreach ($entry in @(
            @{ predicateType = 'https://spdx.dev/Document'; body = $sbomBody }
            $slsaPredicate
        )) {
            if ($entry.predicateType -ceq $MissingPredicate) { continue }
            $subjects = [System.Collections.Generic.List[hashtable]]::new()
            if (-not $EmptySubject) {
                $subjHex = if ($SubjectOverride) { $SubjectOverride } else { $imageDesc.digest.Substring(7) }
                $subjects.Add(@{ digest = @{ sha256 = $subjHex } })
            }
            $attLayers.Add((Add-JsonBlob @{
                predicateType = $entry.predicateType
                predicate     = $entry.body
                subject       = @($subjects.ToArray())
            } 'application/vnd.in-toto+json'))
        }

        $attDesc = Add-JsonBlob @{
            schemaVersion = 2
            mediaType     = 'application/vnd.oci.image.manifest.v1+json'
            layers        = @($attLayers.ToArray())
        }
        $attDesc['platform'] = @{ os = 'unknown'; architecture = 'unknown' }
        $attDesc['annotations'] = @{
            'vnd.docker.reference.digest' = $imageDesc.digest
            'vnd.docker.reference.type'   = 'attestation-manifest'
        }

        $manifests = [System.Collections.Generic.List[hashtable]]::new()
        $manifests.Add($imageDesc)
        $manifests.Add($attDesc)
        if ($ExtraWindowsPlatform) {
            $manifests.Add(@{
                mediaType = 'application/vnd.oci.image.manifest.v1+json'
                digest    = $imageDesc.digest
                size      = $imageDesc.size
                platform  = @{ os = 'windows'; architecture = 'amd64' }
            })
        }

        $indexObj = @{
            schemaVersion = 2
            mediaType     = 'application/vnd.oci.image.index.v1+json'
            manifests     = @($manifests.ToArray())
        }

        if ($WrapLayoutIndex) {
            $wrappedDesc = Add-JsonBlob $indexObj 'application/vnd.oci.image.index.v1+json'
            $wrappedDesc['annotations'] = @{ 'org.opencontainers.image.ref.name' = $Version }
            $rootIndexObj = @{
                schemaVersion = 2
                mediaType     = 'application/vnd.oci.image.index.v1+json'
                manifests     = @($wrappedDesc)
            }
        } else {
            $rootIndexObj = $indexObj
        }

        $indexBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $rootIndexObj -Depth 20 -Compress))
        $layoutBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"imageLayoutVersion":"1.0.0"}')

        $dir = Split-Path -Parent $Path
        if ($dir) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $fs = [IO.File]::Create($Path)
        try {
            $writer = [System.Formats.Tar.TarWriter]::new($fs, [System.Formats.Tar.TarEntryFormat]::Pax, $false)
            try {
                foreach ($name in $blobs.Keys) {
                    $ms = [IO.MemoryStream]::new($blobs[$name], $false)
                    try {
                        $tarEntry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $name)
                        $tarEntry.DataStream = $ms
                        $writer.WriteEntry($tarEntry)
                    } finally { $ms.Dispose() }
                }
                foreach ($metaEntry in @(
                    @{ name = 'index.json'; bytes = $indexBytes }
                    @{ name = 'oci-layout'; bytes = $layoutBytes }
                )) {
                    $ms = [IO.MemoryStream]::new($metaEntry.bytes, $false)
                    try {
                        $tarEntry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, $metaEntry.name)
                        $tarEntry.DataStream = $ms
                        $writer.WriteEntry($tarEntry)
                    } finally { $ms.Dispose() }
                }
            } finally { $writer.Dispose() }
        } finally { $fs.Dispose() }

        if ($Seal) {
            $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $(Split-Path -Leaf $Path)`n" | Set-Content -LiteralPath "$Path.sha256" -NoNewline -Encoding utf8NoBOM
        }

        [pscustomobject]@{
            Path         = $Path
            ImageDigest  = $imageDesc.digest
            ConfigDigest = $configDesc.digest
        }
    }
}

Describe 'OciArtifact .NET 10 file-based OCI tooling' {
    BeforeEach {
        $workDir = Join-Path ([IO.Path]::GetTempPath()) ('docfx-oci-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    AfterEach {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force
        }
    }

    Context 'Verification of OCI archives, labels, blobs, and attestations' {
        It 'verifies a valid single-platform OCI archive with SLSA v0.2 and writes detached checksum' {
            $fixture = New-SyntheticOciArchive -Path (Join-Path $workDir 'amd64.oci.tar') -Cpu amd64 -WrapLayoutIndex
            $res = Invoke-OciTool @('verify', $fixture.Path, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--platform', 'amd64')

            $res.ExitCode | Should -Be 0
            $json = $res.Output | ConvertFrom-Json
            $json.platforms | Should -Be @('amd64')
            $json.configs.amd64 | Should -Be $fixture.ConfigDigest
            Test-Path -LiteralPath "$($fixture.Path).sha256" | Should -BeTrue
        }

        It 'verifies SLSA v1.0 provenance and custom fork source repository' {
            $forkSource = 'https://github.com/fork-owner/docfx'
            $fixture = New-SyntheticOciArchive -Path (Join-Path $workDir 'arm64.oci.tar') -Cpu arm64 -Source $forkSource -UseSlsaV1
            $res = Invoke-OciTool @('verify', $fixture.Path, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--source', $forkSource, '--platform', 'arm64')

            $res.ExitCode | Should -Be 0
            ($res.Output | ConvertFrom-Json).configs.arm64 | Should -Be $fixture.ConfigDigest
        }

        It 'rejects platform mismatch, missing attestations, subject mismatch, and label drift' -ForEach @(
            @{ Name = 'wrong CPU platform'; Params = @{ Cpu = 'amd64' }; Platform = 'arm64'; Expected = '*Unexpected platform inventory*' }
            @{ Name = 'extra untested runtime platform'; Params = @{ Cpu = 'amd64'; ExtraWindowsPlatform = $true }; Platform = 'amd64'; Expected = '*Unexpected runtime*' }
            @{ Name = 'missing SPDX SBOM'; Params = @{ Cpu = 'amd64'; MissingPredicate = 'https://spdx.dev/Document' }; Platform = 'amd64'; Expected = '*SBOM or provenance missing*' }
            @{ Name = 'empty SPDX SBOM'; Params = @{ Cpu = 'amd64'; EmptySbom = $true }; Platform = 'amd64'; Expected = '*Empty SBOM*' }
            @{ Name = 'missing SLSA provenance'; Params = @{ Cpu = 'amd64'; MissingPredicate = 'https://slsa.dev/provenance/v0.2' }; Platform = 'amd64'; Expected = '*SBOM or provenance missing*' }
            @{ Name = 'wrong attestation subject'; Params = @{ Cpu = 'amd64'; SubjectOverride = ('c' * 64) }; Platform = 'amd64'; Expected = '*Attestation subject mismatch*' }
            @{ Name = 'empty attestation subject'; Params = @{ Cpu = 'amd64'; EmptySubject = $true }; Platform = 'amd64'; Expected = '*Attestation subject mismatch*' }
            @{ Name = 'wrong engine version label'; Params = @{ Cpu = 'amd64'; Version = '1.0.9' }; Platform = 'amd64'; Expected = '*Identity mismatch*' }
            @{ Name = 'wrong DocFX CLI version label'; Params = @{ Cpu = 'amd64'; DocfxVersion = '2.80.0' }; Platform = 'amd64'; Expected = '*Identity mismatch*' }
            @{ Name = 'wrong provenance build-arg DOCFX_VERSION'; Params = @{ Cpu = 'amd64'; ProvenanceDocfxVersion = '2.80.0' }; Platform = 'amd64'; Expected = '*Provenance build identity mismatch*' }
            @{ Name = 'missing created timestamp label'; Params = @{ Cpu = 'amd64'; Created = '' }; Platform = 'amd64'; Expected = '*Missing build identity*' }
        ) {
            $path = Join-Path $workDir 'bad.oci.tar'
            $null = New-SyntheticOciArchive -Path $path @Params
            $res = Invoke-OciTool @('verify', $path, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--platform', $Platform, '--no-seal')

            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -BeLike $Expected
        }

        It 'rejects a corrupted OCI blob even after resealing the archive checksum' {
            $fixture = New-SyntheticOciArchive -Path (Join-Path $workDir 'corrupt.oci.tar') -Cpu amd64 -Seal
            $bytes = [IO.File]::ReadAllBytes($fixture.Path)
            $text = [Text.Encoding]::Latin1.GetString($bytes).Replace('synthetic-layer-amd64', 'tampered!-layer-amd64')
            [IO.File]::WriteAllBytes($fixture.Path, [Text.Encoding]::Latin1.GetBytes($text))
            $null = Invoke-OciTool @('seal', $fixture.Path)

            $res = Invoke-OciTool @('verify', $fixture.Path, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--platform', 'amd64', '--check-seal', '--no-seal')
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -BeLike '*Corrupt OCI blob*'
        }

        It 'rejects checksum tampering via check-seal' {
            $fixture = New-SyntheticOciArchive -Path (Join-Path $workDir 'sealed.oci.tar') -Cpu amd64 -Seal
            Add-Content -LiteralPath $fixture.Path -Value 'tamper' -NoNewline

            $res = Invoke-OciTool @('check-seal', $fixture.Path)
            $res.ExitCode | Should -Not -Be 0
            $res.Output | Should -BeLike '*Archive checksum mismatch*'
        }
    }

    Context 'Multi-platform merge, splitting, reassembly, and layout extraction' {
        It 'merges verified amd64 and arm64 archives preserving exact child configs and Codebelt verifier contract' {
            $amd = New-SyntheticOciArchive -Path (Join-Path $workDir 'amd64.oci.tar') -Cpu amd64 -Seal
            $arm = New-SyntheticOciArchive -Path (Join-Path $workDir 'arm64.oci.tar') -Cpu arm64 -Seal
            $mergedPath = Join-Path $workDir 'merged.oci.tar'

            $res = Invoke-OciTool @(
                'merge', $mergedPath
                '--version', $validVersion
                '--docfx-version', $validDocfx
                '--revision', $validRevision
                '--input', $amd.Path
                '--input', $arm.Path
            )
            $res.ExitCode | Should -Be 0
            $merged = $res.Output | ConvertFrom-Json
            $merged.indexDigest | Should -Match '^sha256:[0-9a-f]{64}$'
            $merged.platforms | Should -Be @('amd64', 'arm64')
            $merged.configs.amd64 | Should -Be $amd.ConfigDigest
            $merged.configs.arm64 | Should -Be $arm.ConfigDigest
            Test-Path -LiteralPath "$mergedPath.sha256" | Should -BeTrue

            # Extract layout and verify index.json conforms to codebeltnet/oci-artifact-verify contract
            $layoutDir = Join-Path $workDir 'layout'
            $extractRes = Invoke-OciTool @('extract-layout', $mergedPath, '--output-dir', $layoutDir)
            $extractRes.ExitCode | Should -Be 0

            $outerIndex = Get-Content -LiteralPath (Join-Path $layoutDir 'index.json') -Raw | ConvertFrom-Json
            $outerIndex.manifests.Count | Should -Be 1
            $outerIndex.manifests[0].digest | Should -Be $merged.indexDigest
            $outerIndex.manifests[0].annotations.'org.opencontainers.image.ref.name' | Should -Be $validVersion

            $embeddedHex = $merged.indexDigest.Substring(7)
            $embeddedIndex = Get-Content -LiteralPath (Join-Path $layoutDir "blobs/sha256/$embeddedHex") -Raw | ConvertFrom-Json
            $embeddedIndex.annotations.'org.opencontainers.image.version' | Should -Be $validVersion
            $embeddedIndex.annotations.'org.opencontainers.image.revision' | Should -Be $validRevision
            $embeddedIndex.annotations.'net.codebelt.docfx.cli.version' | Should -Be $validDocfx
        }

        It 'rejects merge when a required platform is missing or duplicated' {
            $amd = New-SyntheticOciArchive -Path (Join-Path $workDir 'amd64.oci.tar') -Cpu amd64 -Seal
            $mergedPath = Join-Path $workDir 'incomplete.oci.tar'

            $missingArm = Invoke-OciTool @('merge', $mergedPath, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--input', $amd.Path)
            $missingArm.ExitCode | Should -Not -Be 0
            $missingArm.Output | Should -BeLike '*Unexpected platform inventory*'

            $dupAmd = Invoke-OciTool @('merge', $mergedPath, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--input', $amd.Path, '--input', $amd.Path)
            $dupAmd.ExitCode | Should -Not -Be 0
            $dupAmd.Output | Should -BeLike '*Duplicate input platform*'
        }

        It 'splits an OCI archive into multiple parts and reconstructs byte-identical content' {
            $amd = New-SyntheticOciArchive -Path (Join-Path $workDir 'amd64.oci.tar') -Cpu amd64 -Seal
            $arm = New-SyntheticOciArchive -Path (Join-Path $workDir 'arm64.oci.tar') -Cpu arm64 -Seal
            $mergedPath = Join-Path $workDir 'docfx.oci.tar'
            $mergeRes = Invoke-OciTool @('merge', $mergedPath, '--version', $validVersion, '--docfx-version', $validDocfx, '--revision', $validRevision, '--input', $amd.Path, '--input', $arm.Path)
            $mergeRes.ExitCode | Should -Be 0
            $originalSha = (Get-FileHash -LiteralPath $mergedPath -Algorithm SHA256).Hash.ToLowerInvariant()

            $partsDir = Join-Path $workDir 'parts'
            $splitRes = Invoke-OciTool @('split', $mergedPath, '--output-dir', $partsDir, '--prefix', 'docfx', '--part-size', '2048', '--write-checksum')
            $splitRes.ExitCode | Should -Be 0
            $splitData = $splitRes.Output | ConvertFrom-Json
            $splitData.pieces.Count | Should -BeGreaterThan 1
            $splitData.archiveSha256 | Should -Be $originalSha

            $manifestPath = Join-Path $workDir 'release.json'
            @{
                ArchiveSha256 = $splitData.archiveSha256
                ArchiveBytes  = $splitData.archiveBytes
                Pieces        = @($splitData.pieces | ForEach-Object { @{ Name = $_.name; Sha256 = $_.sha256; Size = $_.size } })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath

            $rebuiltPath = Join-Path $workDir 'rebuilt/docfx.oci.tar'
            $reassembleRes = Invoke-OciTool @(
                'reassemble'
                '--manifest', $manifestPath
                '--input-dir', $partsDir
                '--output', $rebuiltPath
                '--checksum', (Join-Path $partsDir 'docfx.oci.tar.sha256')
            )
            $reassembleRes.ExitCode | Should -Be 0
            (Get-FileHash -LiteralPath $rebuiltPath -Algorithm SHA256).Hash.ToLowerInvariant() | Should -Be $originalSha

            # Verify tampered piece is rejected during reconstruction
            $firstPart = Join-Path $partsDir $splitData.pieces[0].name
            $partBytes = [IO.File]::ReadAllBytes($firstPart)
            $partBytes[0] = $partBytes[0] -bxor 0xFF
            [IO.File]::WriteAllBytes($firstPart, $partBytes)

            $tamperedRes = Invoke-OciTool @('reassemble', '--manifest', $manifestPath, '--input-dir', $partsDir, '--output', (Join-Path $workDir 'rebuilt2/docfx.oci.tar'))
            $tamperedRes.ExitCode | Should -Not -Be 0
            $tamperedRes.Output | Should -BeLike '*differs from verified release record*'
        }
    }
}
