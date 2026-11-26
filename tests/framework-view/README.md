# Framework view regression tests

All suites use the [framework views generator in this repository](../../framework-views/README.md). Run the commands from the DocFX repository root or its extracted source archive.

Use PowerShell 7 on the host. The native and browser suites also require the .NET 11 SDK and DocFX CLI 2.81.0 on the host PATH. Install .NET 8 side by side for the older SDK test. For HTTP tests, use Docker in Linux-container mode. The browser tests also require Node.js 20 or newer and Chromium.

## Unit tests and coverage

Run with Pester 5. Measure all three PowerShell implementation files so the report includes the generator entry point. The unit tests exercise preflight checks, framework conventions, output ownership, and metadata recovery and publication with the external commands mocked. The native and packaged suites below exercise real project discovery, MSBuild, DocFX, cache reuse, rendering and packaging.

```powershell
$configuration = New-PesterConfiguration
$configuration.Run.Path = 'tests/framework-view/*.Tests.ps1'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = (Get-ChildItem framework-views/*.ps1).FullName
$configuration.CodeCoverage.OutputPath = Join-Path ([IO.Path]::GetTempPath()) 'docfx-framework-views-unit.xml'
$configuration.CodeCoverage.CoveragePercentTarget = 100
Invoke-Pester -Configuration $configuration
```

## Native generation and HTTP routing

```powershell
pwsh -NoProfile -File tests/framework-view/Test-FrameworkViews.ps1 -TestRouting
pwsh -NoProfile -File tests/framework-view/Test-FrameworkViews.ps1 -ProjectSdk8 -TestRouting
```

These exercise glob exclusions, nested metadata destinations, per-view project availability, full assembly identities, inherited overloads, consumer MSBuild hooks, repeat builds, cache reuse, invalidation and isolated recovery. The second command selects .NET 8 for the projects and a modern SDK for the resolver. Without `-TestRouting`, the suite runs without Docker on Windows, Linux or CI.

## Packaged builder and browser regression

Four fixture projects document `/api/runtime/`, `/api/utilities/`, `/api/modern/` (`.NET 11` and `.NET 10` only), and `/api/standard/` (`.NET Standard 2.1` and `.NET Standard 2.0` only), alongside conditional per-type APIs across five framework views. The container test builds the image locally and runs the packaged generator with a clean mounted copy of the fixture. It checks PowerShell, both installed SDKs, DocFX, restore assets, the rendered views and their native xrefs, search indexes, page availability manifest, and NGINX fallback routes. The container-only check requires Docker in Linux-container mode.

```powershell
pwsh -NoProfile -File tests/framework-view/Test-FrameworkView.ps1 -ContainerOnly
```

The complete suite also runs the generator natively and compares the runtime manifest and routing with the container build. It serves the native output and an ordinary single-framework site with the shared NGINX Dockerfile. The browser and HTTP checks cover the selector, UID and fragment resolution, unified default and non-default fallback precedence, global navigation, TOCs, breadcrumbs, cross-references, ordinary internal API hyperlinks, new-tab opening without click interception, JavaScript-disabled navigation, browser history, query parameter and fragment preservation, genuine 404s, invalid-view 400s, strict TOC/xref/search isolation, and mobile keyboard operation.

```powershell
Push-Location tests/framework-view
npm ci
npx playwright install chromium
Pop-Location
pwsh -File tests/framework-view/Test-FrameworkView.ps1
```

On Linux, install Chromium's system dependencies with `npx playwright install --with-deps chromium` if needed. Use `-SkipImageBuild -BuilderImage <image-reference>` to test an existing builder image. For CI-aligned native builder image validation (including OCI labels, architecture, SDKs, PowerShell 7, complete `/opt/docfx/framework-views` distribution, multi-framework build, and single-framework build), run `pwsh -NoProfile -File tests/Test-DocfxContainer.ps1 -Image <image-reference> -Platform linux/amd64`. Official production publication uses the build-once GitHub Actions release and deployment lifecycle described in [CI/CD release and deployment lifecycle](../../README.md#cicd-release-and-deployment-lifecycle).

## Cuemon.Kernel, Cuemon.IO and Cuemon.AspNetCore

The test uses the authored Cuemon project mappings, filter, overwrites, template, and run actions from the [fixture revision](https://github.com/codebeltnet/cuemon/tree/53875b1bbb778067a0a029b87861efdb0b78a8b5). It stages a multi-section configuration (`api/dotnet` for `Cuemon.Kernel` and `Cuemon.IO`; `api/aspnet` for `Cuemon.AspNetCore`) in the consumer checkout, exercising cross-target reference recovery and reproducing the reported `.NET Standard 2.0` -> `ASP.NET Core API` navigation scenario using real Cuemon metadata. Run on Windows or Linux with Git and the native prerequisites above.

```powershell
$scratch = Join-Path ([IO.Path]::GetTempPath()) "docfx-cuemon-$([guid]::NewGuid().ToString('N'))"
$consumer = "$scratch/consumer"
$output = "$scratch/output"
git clone --single-branch --branch v11.0.0/docfx https://github.com/codebeltnet/cuemon.git $consumer
git -C $consumer checkout --detach 53875b1bbb778067a0a029b87861efdb0b78a8b5
pwsh -NoProfile -File tests/framework-view/cuemon/Build-CuemonFixture.ps1 -ConsumerRoot $consumer -OutputRoot $output
pwsh -NoProfile -File tests/framework-view/cuemon/Test-CuemonFrameworkViews.ps1 -Workspace $output
```

The acceptance test checks the native xref inventory against every served API and fragment, page availability metadata, HTTP 302 destination-aware fallback (both default `.NET 11` fallback for `Cuemon.AspNetCore` / `BufferWriterOptions` / `Validator` and non-default `.NET Standard 2.0` fallback for `CallerArgumentExpressionAttribute`), strict TOC/xref/search isolation, overload and inheritance differences, source and run-action links, overwrite examples, and HTTP caching. It expects 937 (557 dotnet + 380 aspnet), 937 (557 dotnet + 380 aspnet), 76 and 548 metadata UIDs in framework order. To use the builder image, run the entire fixture build in the container with the test scripts and a writable fixture checkout mounted. Pass `-Origin <url>` to the acceptance test to check an already running server.
