# Framework view regression tests

The fixture documents two small projects under `/api/runtime/` and `/api/utilities/`. Conditional APIs distinguish the five framework views. The pinned shared OCI generator writes the availability manifest, native xref maps, search indexes and NGINX configuration. The generator renders with the repository's Docker builder image and extracts `ms-style` from that image. It also serves a separate, standard single-framework build without framework metadata.

Run from the repository root with PowerShell 7, Docker in Linux-container mode, .NET 11 SDK, DocFX CLI 2.81.0 on the host PATH, and Node.js 20 or newer. Git, NuGet and Docker image downloads require network access.

```powershell
Push-Location tests/framework-view
npm ci
npx playwright install chromium
Pop-Location
pwsh -File tests/framework-view/Test-FrameworkView.ps1
```

On Linux, install Chromium's system dependencies with `npx playwright install --with-deps chromium` if needed. To check another local revision of the shared action, pass `-ActionPath` with its checkout path. Use `-SkipImageBuild -BuilderImage <tag>` to test an existing builder image.
