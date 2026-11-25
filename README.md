# DocFX Builder

This repository distributes the DocFX builder image, shared templates and native multi-framework documentation generator.

Framework views generate one native set of API pages, xrefs and search results per evaluated project target framework. From the consumer repository root, the generator reads `.docfx/docfx.json` and writes to `.bot/docfx`. The same PowerShell entry point runs on Windows, Linux, CI and in the builder image. Ordinary DocFX sites continue to use the standard CLI. [Framework views setup and migration](framework-views/README.md)

Consuming repositories only need to provide their DocFX metadata and content with a command such as `ADD [".", "docfx"]` in their documentation Dockerfile.

The image includes DocFX's `default` and `modern` templates and the Codebelt `ms-style` compatibility overlay. The overlay is intended for API reference sites maintained by the Codebelt ecosystem, including:

- [Cuemon](https://github.com/codebeltnet/cuemon)
- [SavvyIO](https://github.com/codebeltnet/savvyio)
- [Shared-Kernel](https://github.com/codebeltnet/shared-kernel)
- [Unitify](https://github.com/codebeltnet/unitify)
- [Bootstrapper](https://github.com/codebeltnet/bootstrapper)
- [xUnit](https://github.com/codebeltnet/xunit)
- [BenchmarkDotNet](https://github.com/codebeltnet/benchmarkdotnet)
- [YamlDotNet](https://github.com/codebeltnet/yamldotnet)
- [Carter](https://github.com/codebeltnet/carter)
- [Globalization](https://github.com/codebeltnet/globalization)
- [ASP.NET API Versioning](https://github.com/codebeltnet/asp-versioning)
- [Swashbuckle.AspNetCore](https://github.com/codebeltnet/swashbuckle-aspnetcore)
- [Newtonsoft.Json](https://github.com/codebeltnet/newtonsoft-json)
- [AWS Signature V4](https://github.com/codebeltnet/aws-signature-v4)

An existing build can adopt the shared template with a small `docfx.json` change:

```json
{
  "build": {
    "template": [
      "default",
      "modern",
      "templates/ms-style"
    ]
  }
}
```

DocFX merges templates from left to right. Keep an existing repository template before `templates/ms-style` when it supplies repository-specific partials that should remain available.

Put a deliberate local override after `templates/ms-style` when it must take precedence.

For Microsoft Learn-style type pages, add `memberLayout` to every managed-reference metadata entry:

```json
{
  "metadata": [
    {
      "src": [ /* existing project sources */ ],
      "dest": "api",
      "memberLayout": "separatePages"
    }
  ]
}
```

This preserves existing generated YAML, Markdown, TOCs, overwrite files, filters, and source-link metadata.

`ms-style` changes the API reading surface with:

- type-first headings such as `DateTime Struct` and a Definition/facts block;
- Learn-like type/member tables, namespace category tables, and a narrow article column with a wide-screen navigation rail that collapses into an inline article outline on narrower desktops; and
- responsive light/dark styling.

It does not reproduce Microsoft's dynamic global navigation, account controls, product switcher, or other Learn platform services. Those are outside a DocFX template's responsibility.

The smooth migration path is therefore:

1. build or update the shared DocFX image so it contains `ms-style`;
2. append `templates/ms-style` to the existing template array;
3. set `memberLayout` to `separatePages` for each API metadata source;
4. build and visually review one representative type and member page; and
5. remove only custom template files that duplicate the shared shell after the new output has been accepted.

The shared image contains the template files. After changing `ms-style`, rebuild the shared image before rebuilding consuming repositories. Without `--pull`, Docker uses an existing local image with the requested tag and downloads it only when that image is not available locally. This supports a local-first feedback loop without accidentally replacing a locally built image with the published one.

Static documentation hosts should serve content-hashed assets with a long-lived `immutable` policy and serve stable DocFX URLs with `Cache-Control: no-store`. The `ms-style` page shell also requests same-origin JSON with the Fetch API's `no-store` cache mode. This bypasses navigation data cached before explicit response policies were added; response headers alone cannot invalidate an entry when the browser satisfies the request without contacting the server.

The visual target is the .NET API reference surface represented by [Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/system.datetime?view=net-10.0).

API source and content conventions are informed by [dotnet-api-docs](https://github.com/dotnet/dotnet-api-docs) and [dotnet/docs](https://github.com/dotnet/docs).

For the underlying template model, see:

- [DocFX template documentation](https://dotnet.github.io/docfx/docs/template.html)
- [Custom-template merge guidance](https://dotnet.github.io/docfx/tutorial/howto_create_custom_template.html)
- [DocFX template CLI reference](https://dotnet.github.io/docfx/reference/docfx-cli-reference/docfx-template.html)

## Docker image versioning

The `codebeltnet/docfx` distribution versions two independent dimensions:

- **DocFX CLI version:** the upstream DocFX CLI and upstream templates packaged in the image (for example, `2.81.0`).
- **Codebelt engine version:** the Semantic Versioning release of `codebeltnet/docfx` itself, covering the `ms-style` template, multi-framework views generator, MSBuild discovery, metadata recovery, and container packaging (for example, `1.1.0`).

Neither version is inferred from the other. The examples below use DocFX CLI `2.81.0` and Codebelt engine `1.1.0` to illustrate the implemented naming contract; they do not assert that the `1.1.0` tags are publicly available in a registry before release publication occurs.

### Convenience and engine-qualified tags

For a standard stable release containing one upstream DocFX CLI version, a single multi-platform build associates all seven tags with the same published image index:

| Tag family | Image tag | Meaning |
| --- | --- | --- |
| Convenience | `codebeltnet/docfx:latest` | Latest published distribution |
| Convenience | `codebeltnet/docfx:2` | Latest published distribution within DocFX CLI major version `2` |
| Convenience | `codebeltnet/docfx:2.81` | Latest published distribution within DocFX CLI minor version `2.81` |
| Convenience | `codebeltnet/docfx:2.81.0` | Distribution using exact DocFX CLI version `2.81.0` |
| Engine-qualified | `codebeltnet/docfx:2-v1.1.0` | DocFX CLI major version `2` with Codebelt engine `1.1.0` |
| Engine-qualified | `codebeltnet/docfx:2.81-v1.1.0` | DocFX CLI minor version `2.81` with Codebelt engine `1.1.0` |
| Engine-qualified | `codebeltnet/docfx:2.81.0-v1.1.0` | Exact DocFX CLI `2.81.0` with Codebelt engine `1.1.0` |

Prerelease versions never update floating stable convenience tags:

- A prerelease Codebelt engine version (for example, `1.2.0-rc.1` with DocFX CLI `2.81.0`) generates only the engine-qualified tags (`2.81.0-v1.2.0-rc.1`, `2.81-v1.2.0-rc.1`, `2-v1.2.0-rc.1`).
- A prerelease DocFX CLI version (for example, `2.82.0-preview.1` with stable Codebelt engine `1.2.0`) generates only the exact CLI tags (`2.82.0-preview.1-v1.2.0` and `2.82.0-preview.1`), or only `2.82.0-preview.1-v1.2.0-rc.1` when both dimensions are prereleases.

### Consumer control levels

Existing consumers do not need to migrate; unqualified convenience tags remain supported with their established behavior. Choose the reference level that matches your reproducibility needs:

- **Convenience** (for example, `codebeltnet/docfx:2` or `codebeltnet/docfx:2.81.0`): automatically receives updated Codebelt engine releases for that DocFX CLI scope. Convenient for low-maintenance builds, but pulling a newer image can introduce breaking Codebelt engine changes independently of the upstream DocFX CLI.
- **Explicit version selection** (for example, `codebeltnet/docfx:2-v1.1.0` or `codebeltnet/docfx:2.81.0-v1.1.0`): selects a specific Codebelt engine release. Published engine-qualified release tags are never intentionally reassigned to different image content during ordinary release operations, and `BuildAndPushDocfxImage.ps1 -Publish` refuses to overwrite existing engine-qualified tags. Because these tags stay fixed to one release, they do not automatically receive future patches or security updates; adopt a newer `-v<EngineVersion>` release explicitly.
- **Immutable reproducibility** (for example, `codebeltnet/docfx:2.81.0-v1.1.0@sha256:<published-image-index-digest>`): Docker tags themselves are mutable pointers by nature. Pinning the published multi-platform image index digest provides content-addressed immutability.

Client-side preflight checks cannot prevent a race condition against concurrent or external registry writers. Where supported by the destination registry, enable selective registry-enforced immutable-tag rules for engine-qualified tags (for example, Docker Hub immutable-tag pattern `^.+-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$`) while keeping convenience tags movable.

### OCI image metadata

Every image built with `Dockerfile` and `BuildAndPushDocfxImage.ps1` records both versioning dimensions and source provenance through OCI labels:

| OCI label | Purpose |
| --- | --- |
| `org.opencontainers.image.version` | Codebelt engine version (`-EngineVersion`, set on published releases and local builds that pass `-EngineVersion`) |
| `net.codebelt.docfx.engine.version` | Explicit Codebelt engine version paired with the CLI version label |
| `net.codebelt.docfx.cli.version` | Upstream DocFX CLI version packaged in the image |
| `org.opencontainers.image.revision` | Git commit SHA of the `codebeltnet/docfx` build source |
| `org.opencontainers.image.created` | RFC 3339 UTC build timestamp |
| `org.opencontainers.image.source` / `org.opencontainers.image.url` | Canonical repository URL (`https://github.com/codebeltnet/docfx`) |
| `org.opencontainers.image.title` / `description` / `vendor` / `licenses` | Distribution identity and MIT license metadata |

## Build the builder image locally

From the repository root, use PowerShell 7 and Docker Buildx in Linux-container mode.

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Tag docfx-local
```

Without `-EngineVersion`, the default loads one platform into Docker and tags it with the existing convenience tags (`docfx-local:2.81.0`, `docfx-local:2.81`, `docfx-local:2`, and `docfx-local:latest`). Pass `-EngineVersion` to also generate the engine-qualified tags and set `org.opencontainers.image.version` locally:

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Tag docfx-local -EngineVersion 1.1.0
docker inspect --format '{{json .Config.Labels}}' docfx-local:2.81.0-v1.1.0
```

Supply `-Platform linux/amd64` or `-Platform linux/arm64` to select a platform explicitly. AMD64 uses Alpine and ARM64 uses Ubuntu 26.04, whose .NET 11 SDK includes PowerShell 7 on ARM64. Use the corresponding package manager when extending either image.

The script accepts `-DocfxVersion` for the upstream CLI and templates, `-EngineVersion` for the Codebelt engine Semantic Version (without a leading `v` or `+` build metadata), and `-DotnetVersion` for the SDK and runtime used by DocFX. The defaults package DocFX `2.81.0` and the .NET 10 and .NET 11 SDKs. Use `-FrameworkSdkImage` or `-FrameworkSdkArm64Image` to override the final SDK base on the corresponding platform. Keep the base's C library compatible with that platform's SDK stage and ensure the base supplies PowerShell 7. The [framework views compatibility contract](framework-views/README.md#template-compatibility) applies when changing the CLI or template.

To run the builder versioning and publication-safeguard unit tests with Pester 5 and verify 100% coverage of `BuildAndPushDocfxImage.ps1`:

```powershell
$configuration = New-PesterConfiguration
$configuration.Run.Path = 'tests/BuildAndPushDocfxImage.Tests.ps1'
$configuration.CodeCoverage.Enabled = $true
$configuration.CodeCoverage.Path = 'BuildAndPushDocfxImage.ps1'
$configuration.CodeCoverage.OutputPath = Join-Path ([IO.Path]::GetTempPath()) 'docfx-image-unit.xml'
$configuration.CodeCoverage.CoveragePercentTarget = 100
Invoke-Pester -Configuration $configuration
```

## Publish and verify the builder image

For an authorized release, select a Buildx builder that can build `linux/amd64` and `linux/arm64`, using native nodes or emulation. Use `docker buildx inspect --bootstrap` to check the builder's platforms. If needed, create a builder with `docker buildx create --driver docker-container --name docfx-release --use`. Sign in to the destination registry and run the publishing script from the repository root with an explicit `-EngineVersion`:

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -EngineVersion 1.1.0 -Publish
```

Publishing requires both `-Publish` and an explicit `-EngineVersion`, along with a clean Git commit revision (`git rev-parse HEAD`). Before building or pushing, the script inspects every engine-qualified destination tag in the registry and stops if any tag already exists or if the registry check fails unexpectedly. It then performs one multi-platform build (`linux/arm64` and `linux/amd64`) and pushes all applicable tags to the single resulting image index. After pushing, it verifies that every published tag resolves to the built image index digest and inspects both required platform image configs to verify their OS, architecture, and OCI version and revision labels. On success it prints `codebeltnet/docfx:2.81.0-v1.1.0@sha256:<published-image-index-digest>`. Use `-ContainerRegistry` and `-Tag` for a different registry namespace or repository.

Inspect the published engine-qualified tag to retrieve the index digest and platform list after release:

```powershell
docker buildx imagetools inspect codebeltnet/docfx:2.81.0-v1.1.0
```

Use the top-level `Digest` field in `codebeltnet/docfx:2.81.0-v1.1.0@sha256:<published-image-index-digest>`. Record the digest from the approved release alongside the source commit. Convenience tags (`latest`, `2`, `2.81`, `2.81.0`) can move when the Codebelt engine or upstream CLI updates, while engine-qualified tags (`2-v1.1.0`, `2.81-v1.1.0`, `2.81.0-v1.1.0`) identify one published release and digest pinning provides content-addressed immutability. See [Run in the builder image](framework-views/README.md#run-in-the-builder-image) for the consumer command.
