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

function Repair-CrossTargetReferences($Metadata, $Projects, [string] $Tfm, [string] $Stage, [string] $TargetsFile) {
    $retry = $false
    foreach ($group in $Metadata) {
        $availableHooks = [Collections.Generic.List[string]]::new()
        $availableHooks.Add('CustomAfterMicrosoftCommonTargets')
        $availableHooks.Add('CustomBeforeMicrosoftCommonTargets')
        $affected = @(
            foreach ($project in Get-MappedProjectPaths $group) {
                $info = $Projects[$project]
                $log = "$Stage/references-$($info.id).log"
                Invoke-Step $log dotnet (@('msbuild', $project, '-nologo', "-p:TargetFramework=$Tfm",
                    '-p:DesignTimeBuild=true', '-p:BuildProjectReferences=false', '-t:PrepareProjectReferences',
                    '-getItem:_MSBuildProjectReferenceExistent', '-getProperty:CustomAfterMicrosoftCommonTargets,CustomBeforeMicrosoftCommonTargets') + $info.properties)
                $evaluation = Read-MSBuildJson (Get-Content -LiteralPath $log) $project
                $reference = $evaluation.Items._MSBuildProjectReferenceExistent | Where-Object {
                    $_.ReferenceOutputAssembly -eq 'true' -and $_.NearestTargetFramework -and $_.NearestTargetFramework -cne $Tfm
                } | Select-Object -First 1
                if ($reference) { $project }
                foreach ($hook in $availableHooks.ToArray()) {
                    $path = $evaluation.Properties.$hook
                    if ($path -and (Test-Path -LiteralPath ([IO.Path]::GetFullPath($path, (Split-Path -Parent $project))) -PathType Leaf)) {
                        [void]$availableHooks.Remove($hook)
                    }
                }
            }
        )
        if (!$affected.Count) { continue }
        if (!$availableHooks.Count) {
            throw "Cross-target DocFX recovery needs an unused CustomAfterMicrosoftCommonTargets or CustomBeforeMicrosoftCommonTargets hook. See '$Stage/metadata.log'."
        }
        foreach ($project in $affected) {
            $info = $Projects[$project]
            Invoke-Step "$Stage/build-$($info.id).log" dotnet (@('build', $project, '-f', $Tfm, '--no-restore') + $info.properties)
        }
        $group.properties[$availableHooks[0]] = $TargetsFile
        $retry = $true
    }
    $retry
}
