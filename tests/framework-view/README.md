# Framework view regression tests

All suites use the [framework views generator in this repository](../../framework-views/README.md). Run the commands from the DocFX repository root or its extracted source archive.

Use PowerShell 7 on the host. The native and browser suites also require the .NET 11 SDK and DocFX CLI 2.81.0 on the host PATH. Install .NET 8 side by side for the older SDK test. For HTTP tests, use Docker in Linux-container mode. The browser tests also require Node.js 20 or newer and Chromium.

## Native generation and HTTP routing

```powershell
pwsh -NoProfile -File tests/framework-view/Test-FrameworkViews.ps1 -TestRouting
pwsh -NoProfile -File tests/framework-view/Test-FrameworkViews.ps1 -ProjectSdk8 -TestRouting
```

These exercise glob exclusions, nested metadata destinations, per-view project availability, cache reuse, invalidation and isolated recovery. The second command selects .NET 8 for the projects and a modern SDK for the resolver. Without `-TestRouting`, the suite runs without Docker on Windows, Linux or CI.

## Packaged builder and browser regression

Two fixture projects document `/api/runtime/` and `/api/utilities/`. Conditional APIs distinguish five framework views. The container test builds the image locally and runs the packaged generator with a clean mounted copy of the fixture. It checks PowerShell, both installed SDKs, DocFX, restore assets, the rendered views and their native xrefs, search indexes, and NGINX routes. The container-only check requires Docker in Linux-container mode.

```powershell
pwsh -NoProfile -File tests/framework-view/Test-FrameworkView.ps1 -ContainerOnly
```

The complete suite also tests the host generator with the image providing rendering. It serves that output and an ordinary single-framework site with the shared NGINX Dockerfile. The browser checks cover the selector, UID and fragment resolution, fallback, direct URLs, navigation, search, and mobile keyboard operation.

```powershell
Push-Location tests/framework-view
npm ci
npx playwright install chromium
Pop-Location
pwsh -File tests/framework-view/Test-FrameworkView.ps1
```

On Linux, install Chromium's system dependencies with `npx playwright install --with-deps chromium` if needed. Use `-SkipImageBuild -BuilderImage <image-reference>` to test an existing builder image. Registry publication and post-publish verification require release approval and registry access. See the [release procedure](../../README.md#publish-and-verify-the-builder-image).

## Cuemon.Kernel and Cuemon.IO

The test uses the authored Cuemon project mappings, filter, overwrites, template, and run actions from the [fixture revision](https://github.com/codebeltnet/cuemon/tree/53875b1bbb778067a0a029b87861efdb0b78a8b5). It stages a two-project configuration in the consumer checkout and enables assembly-version alignment for the mixed target graph. Run on Windows or Linux with Git and the native prerequisites above.

```powershell
$scratch = Join-Path ([IO.Path]::GetTempPath()) "docfx-cuemon-$([guid]::NewGuid().ToString('N'))"
$consumer = "$scratch/consumer"
$output = "$scratch/output"
git clone --single-branch --branch v11.0.0/docfx https://github.com/codebeltnet/cuemon.git $consumer
git -C $consumer checkout --detach 53875b1bbb778067a0a029b87861efdb0b78a8b5
pwsh -NoProfile -File tests/framework-view/cuemon/Build-CuemonFixture.ps1 -ConsumerRoot $consumer -OutputRoot $output
pwsh -NoProfile -File tests/framework-view/cuemon/Test-CuemonFrameworkViews.ps1 -Workspace $output
```

The acceptance test checks the native xref inventory against every served API and fragment, framework-specific TOCs and search, overload and inheritance differences, source and run-action links, overwrite examples, and HTTP caching. It expects 557, 557, 76 and 548 metadata UIDs in framework order. Pass `-BuilderImage <image-reference>` to the fixture build to render in the container, or `-Origin <url>` to the acceptance test to check an already running server.
