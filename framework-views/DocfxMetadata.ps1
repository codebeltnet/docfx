function Write-Json([string] $Path, $Value) {
    ConvertTo-Json -InputObject $Value -Depth 100 | Set-Content -LiteralPath $Path
}

function Read-Json([string] $Path) {
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
}

function Read-MSBuildJson([string[]] $Output, [string] $Project) {
    # SDK first-run messages and project warnings can precede the property JSON.
    $outputText = $Output -join "`n"
    $json = [regex]::Match($outputText, '(?ms)^\{\n.*?^\}$')
    if (!$json.Success) { throw "MSBuild did not return evaluation JSON for ${Project}: $outputText" }
    $json.Value | ConvertFrom-Json
}

function Get-MappedProjectPaths($Group) {
    foreach ($mapping in $Group.src) {
        foreach ($file in $mapping.files) { [IO.Path]::GetFullPath((Join-Path $mapping.src $file)) }
    }
}

function Clear-StagedMetadata([string] $Destination, [string] $Manifest) {
    Assert-SafeOutputPath $Destination
    if (!(Test-Path -LiteralPath $Destination -PathType Container)) { return }
    $generatedToc = if (Test-Path -LiteralPath $Manifest -PathType Leaf) { Join-Path $Destination 'toc.yml' }
    Get-ChildItem -LiteralPath $Destination -Recurse -File -Force | Where-Object {
        $_.FullName -ceq $generatedToc -or $_.Name -eq '.manifest' -or
        ($_.Extension -eq '.yml' -and (Get-Content -LiteralPath $_.FullName -TotalCount 1) -match '^### YamlMime:(ManagedReference|ApiPage|TableOfContent)\s*$')
    } | Remove-Item -Force
}

function Repair-DocfxProjectReferences($Metadata, $Projects, [string] $Tfm, [string] $Stage, [string] $TargetsFile,
    [string[]] $MissingProjects) {
    $retry = $false
    foreach ($group in $Metadata) {
        $availableHooks = [Collections.Generic.List[string]]::new()
        foreach ($hook in 'CustomAfterMicrosoftCommonTargets', 'CustomBeforeMicrosoftCommonTargets') {
            if ($hook -notin $group.properties.Keys) { $availableHooks.Add($hook) }
        }
        $enableReferenceAssemblies = $false
        $affected = @(
            foreach ($project in Get-MappedProjectPaths $group) {
                $info = $Projects[$project]
                $log = "$Stage/references-$($info.id).log"
                Invoke-Step $log dotnet (@('msbuild', $project, '-nologo', "-p:TargetFramework=$Tfm",
                    '-p:DesignTimeBuild=true', '-p:BuildProjectReferences=false', '-t:PrepareProjectReferences',
                    '-getItem:_MSBuildProjectReferenceExistent', '-getProperty:CustomAfterMicrosoftCommonTargets,CustomBeforeMicrosoftCommonTargets,ProduceReferenceAssembly') + $info.properties)
                $evaluation = Read-MSBuildJson (Get-Content -LiteralPath $log) $project
                $references = @($evaluation.Items._MSBuildProjectReferenceExistent | Where-Object {
                    $_.ReferenceOutputAssembly -eq 'true' -and $_.NearestTargetFramework
                })
                if ($references | Where-Object NearestTargetFramework -CNE $Tfm | Select-Object -First 1) { $project }
                if ($MissingProjects.Count -and 'ProduceReferenceAssembly' -notin $group.properties.Keys -and
                    $evaluation.Properties.ProduceReferenceAssembly -eq 'false') {
                    # With reference assemblies disabled, Roslyn can lose same-target edges even after a build.
                    if ($references | Where-Object {
                        $_.NearestTargetFramework -ceq $Tfm -and
                        ($_.FullPath -cin $MissingProjects -or ($IsWindows -and $_.FullPath -in $MissingProjects))
                    } | Select-Object -First 1) { $enableReferenceAssemblies = $true }
                }
                foreach ($hook in $availableHooks.ToArray()) {
                    $path = $evaluation.Properties.$hook
                    if ($path -and (Test-Path -LiteralPath ([IO.Path]::GetFullPath($path, (Split-Path -Parent $project))) -PathType Leaf)) {
                        [void]$availableHooks.Remove($hook)
                    }
                }
            }
        )
        if ($affected.Count) {
            if (!$availableHooks.Count) {
                throw "Cross-target DocFX recovery needs an unused CustomAfterMicrosoftCommonTargets or CustomBeforeMicrosoftCommonTargets hook. See '$Stage/metadata.log'."
            }
            foreach ($project in $affected) {
                $info = $Projects[$project]
                $arguments = @('build', $project, '-f', $Tfm, '--no-restore') + $info.properties
                if ($enableReferenceAssemblies) { $arguments += '-p:ProduceReferenceAssembly=true' }
                Invoke-Step "$Stage/build-$($info.id).log" dotnet $arguments
            }
            $group.properties[$availableHooks[0]] = $TargetsFile
        }
        if ($enableReferenceAssemblies) { $group.properties.ProduceReferenceAssembly = 'true' }
        if ($affected.Count -or $enableReferenceAssemblies) { $retry = $true }
    }
    $retry
}

function Get-MetadataFingerprint([string[]] $Directories) {
    $entries = foreach ($directory in $Directories) {
        if (!(Test-Path -LiteralPath "$directory/.manifest" -PathType Leaf)) { return }
        foreach ($file in Get-ChildItem -LiteralPath $directory -Recurse -File -Force | Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } | Sort-Object FullName -CaseSensitive) {
            "$([IO.Path]::GetRelativePath($directory, $file.FullName).Replace('\', '/'))=$((Get-FileHash -LiteralPath $file.FullName).Hash)"
        }
    }
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))))
}

function Get-MetadataCount([string[]] $Directories, [string] $View) {
    $count = 0
    foreach ($directory in $Directories) { $count += (Read-Json "$directory/.manifest").Count }
    if (!$count) { throw "Empty DocFX metadata for $View." }
    $count
}

function New-DocfxMetadata($Metadata, $Projects, [string] $Tfm, [string] $View, [string] $Stage,
    [string] $TargetsFile, [string] $Docfx, [string] $CacheFile) {
    $metadataPath = "$Stage/framework-metadata.json"
    $metadataLog = "$Stage/metadata.log"
    $metadataArguments = @('metadata', $metadataPath, '--noRestore')
    $directories = @($Metadata | ForEach-Object { "$Stage/$($_.dest)" })
    $missingReference = 'Found project reference without a matching metadata reference'

    $exitCode = Invoke-Step $metadataLog $Docfx $metadataArguments -ReturnExitCode
    # DocFX may succeed with incomplete output or fail with duplicate assembly identities.
    $referenceWarnings = @(Select-String -LiteralPath $metadataLog -Pattern "$missingReference(?::\s*(.+))?")
    if ($referenceWarnings.Count) {
        $missingProjects = @($referenceWarnings | ForEach-Object { $_.Matches[0].Groups[1].Value.Trim() })
        if (!(Repair-DocfxProjectReferences $Metadata $Projects $Tfm $Stage $TargetsFile $missingProjects)) {
            throw "DocFX metadata for $View has unresolved project references and recovery was unavailable. Check the project references and target frameworks in '$metadataLog'."
        }
        Move-Item -LiteralPath $metadataLog -Destination "$Stage/metadata-before-recovery.log"
        foreach ($directory in $directories) { Clear-StagedMetadata $directory "$directory/.manifest" }
        Write-Json $metadataPath @{ metadata = $Metadata }
        $exitCode = Invoke-Step $metadataLog $Docfx $metadataArguments -ReturnExitCode
        if (Select-String -LiteralPath $metadataLog -SimpleMatch $missingReference -Quiet) {
            throw "DocFX metadata for $View still has unresolved project references after recovery. Check '$metadataLog' and '$Stage/metadata-before-recovery.log'."
        }
    }
    if ($exitCode -ne 0 -or (Select-String -LiteralPath $metadataLog -Pattern '^error:' -Quiet)) {
        throw "DocFX metadata failed for $View. See $metadataLog."
    }
    $fingerprint = Get-MetadataFingerprint $directories
    if (!$fingerprint) { throw "Incomplete metadata for $View. See $metadataLog." }
    $count = Get-MetadataCount $directories $View
    if (!$CacheFile) { return $count }

    $temporary = Join-Path (Split-Path -Parent $Stage) "generated-$Tfm"
    foreach ($group in $Metadata) {
        $destination = "$temporary/$($group.dest)"
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Get-ChildItem -LiteralPath "$Stage/$($group.dest)" -Recurse -File -Force | Where-Object { $_.Extension -eq '.yml' -or $_.Name -eq '.manifest' } | ForEach-Object {
            $output = Join-Path $destination ([IO.Path]::GetRelativePath("$Stage/$($group.dest)", $_.FullName))
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $output
        }
    }
    Set-Content -LiteralPath "$temporary/fingerprint" -Value $fingerprint
    $archive = "$CacheFile-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory($temporary, $archive)
        [IO.File]::Move($archive, $CacheFile, $true)
    } finally {
        [IO.File]::Delete($archive)
    }
    $count
}
