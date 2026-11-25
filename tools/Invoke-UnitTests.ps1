#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $CoverageOutputDir = (Join-Path ([IO.Path]::GetTempPath()) 'docfx-coverage'),
    [switch] $SkipOciTests
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Import-Module Pester -MinimumVersion 5.0.0 -MaximumVersion 5.99.99 -ErrorAction Stop
New-Item -ItemType Directory -Path $CoverageOutputDir -Force | Out-Null

$suites = @(
    @{
        Name       = 'framework-views'
        Tests      = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests/framework-view') -Filter '*.Tests.ps1' -File | Sort-Object FullName | Select-Object -ExpandProperty FullName)
        Coverage   = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'framework-views') -Filter '*.ps1' -File | Sort-Object FullName | Select-Object -ExpandProperty FullName)
        OutputFile = Join-Path $CoverageOutputDir 'docfx-framework-views-coverage.xml'
    }
    @{
        Name       = 'delivery-tooling'
        Tests      = @(
            (Join-Path $repoRoot 'tests/BuildAndPushDocfxImage.Tests.ps1')
            (Join-Path $repoRoot 'tests/ReleaseDelivery.Tests.ps1')
        )
        Coverage   = @(
            (Join-Path $repoRoot 'BuildAndPushDocfxImage.ps1')
            (Join-Path $repoRoot 'tools/DocfxImage.psm1')
            (Join-Path $repoRoot 'tools/Invoke-DocfxRelease.ps1')
        )
        OutputFile = Join-Path $CoverageOutputDir 'docfx-delivery-coverage.xml'
    }
)

foreach ($suite in $suites) {
    Write-Host "=== Running Pester suite: $($suite.Name) (target coverage: 100%) ==="
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $suite.Tests
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $configuration.CodeCoverage.Enabled = $true
    $configuration.CodeCoverage.Path = $suite.Coverage
    $configuration.CodeCoverage.OutputPath = $suite.OutputFile
    $configuration.CodeCoverage.CoveragePercentTarget = 100

    $result = Invoke-Pester -Configuration $configuration
    if ($result.FailedCount -gt 0) {
        throw "Pester suite '$($suite.Name)' failed with $($result.FailedCount) failing test(s)."
    }
    $coveragePercent = $result.CodeCoverage.CoveragePercent
    if ($coveragePercent -lt 100) {
        throw "Pester suite '$($suite.Name)' achieved $coveragePercent% coverage, below required 100%."
    }
}

if (-not $SkipOciTests) {
    Write-Host '=== Running .NET 10 OCI Artifact tool tests ==='
    $ociConfig = New-PesterConfiguration
    $ociConfig.Run.Path = Join-Path $repoRoot 'tests/OciArtifact.Tests.ps1'
    $ociConfig.Run.PassThru = $true
    $ociConfig.Output.Verbosity = 'Normal'
    $ociResult = Invoke-Pester -Configuration $ociConfig
    if ($ociResult.FailedCount -gt 0) {
        throw "OCI artifact test suite failed with $($ociResult.FailedCount) failing test(s)."
    }
}

Write-Host 'All unit test suites passed with 100% measured PowerShell coverage.'
