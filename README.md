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

For a standard stable release containing one upstream DocFX CLI version, a single multi-platform build associates all six versioned tags with the same published image index:

| Tag family | Image tag | Meaning |
| --- | --- | --- |
| Convenience | `codebeltnet/docfx:2` | Latest published distribution within DocFX CLI major version `2` |
| Convenience | `codebeltnet/docfx:2.81` | Latest published distribution within DocFX CLI minor version `2.81` |
| Convenience | `codebeltnet/docfx:2.81.0` | Distribution using exact DocFX CLI version `2.81.0` |
| Engine-qualified | `codebeltnet/docfx:2-v1.1.0` | DocFX CLI major version `2` with Codebelt engine `1.1.0` |
| Engine-qualified | `codebeltnet/docfx:2.81-v1.1.0` | DocFX CLI minor version `2.81` with Codebelt engine `1.1.0` |
| Engine-qualified | `codebeltnet/docfx:2.81.0-v1.1.0` | Exact DocFX CLI `2.81.0` with Codebelt engine `1.1.0` |

**Versioned tagging policy:** `codebeltnet/docfx` does not generate, publish, or support a `:latest` Docker image tag. Consumers should always select an explicit versioned convenience tag (`2`, `2.81`, or `2.81.0`), a Codebelt engine-qualified tag (`2-v1.1.0`, `2.81-v1.1.0`, or `2.81.0-v1.1.0`), or a digest-pinned reference.

Prerelease versions never update floating stable convenience tags:

- A prerelease Codebelt engine version (for example, `1.2.0-rc.1` with DocFX CLI `2.81.0`) generates only the engine-qualified tags (`2.81.0-v1.2.0-rc.1`, `2.81-v1.2.0-rc.1`, `2-v1.2.0-rc.1`).
- A prerelease DocFX CLI version (for example, `2.82.0-preview.1` with stable Codebelt engine `1.2.0`) generates only the exact CLI tags (`2.82.0-preview.1-v1.2.0` and `2.82.0-preview.1`), or only `2.82.0-preview.1-v1.2.0-rc.1` when both dimensions are prereleases.

### Consumer control levels

Versioned convenience tags (`2`, `2.81`, `2.81.0`) remain supported, while `:latest` is intentionally not published or supported. Choose the reference level that matches your reproducibility needs:

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

From the repository root, use PowerShell 7 and Docker Buildx in Linux-container mode. The authoritative upstream DocFX CLI version is declared once in [`Dockerfile`](Dockerfile) (`ARG DOCFX_VERSION=2.81.0`) and validated against `framework-views/Build-DocfxFrameworkViews.ps1` and `templates/ms-style/framework-views.compat`.

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Tag docfx-local
```

Without `-EngineVersion`, the default loads one platform into Docker and tags it with the versioned convenience tags (`docfx-local:2.81.0`, `docfx-local:2.81`, and `docfx-local:2`). Pass `-EngineVersion` to also generate the engine-qualified tags and set `org.opencontainers.image.version` locally:

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Tag docfx-local -EngineVersion 1.1.0
docker inspect --format '{{json .Config.Labels}}' docfx-local:2.81.0-v1.1.0
```

To plan tags and OCI metadata offline without invoking Docker or Git:

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -EngineVersion 1.1.0 -BuildOnly -Platform linux/amd64 -WhatIf -PassThru
```

To execute the same build-once OCI export, SBOM/provenance verification, Skopeo load, native container test suite (`tests/Test-DocfxContainer.ps1`), and loaded-config digest check used by CI (with no registry writes):

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -BuildOnly -EngineVersion 1.1.0 -Platform linux/amd64 -RequireNative -PassThru
```

`-BuildOnly` requires an OCI-capable Buildx `docker-container` builder (for example, `docker buildx create --driver docker-container --name docfx-builder --use`) and either native `skopeo` or a local Docker daemon (`unix://` / `npipe://`) for the pinned `quay.io/skopeo/stable:v1.20.0` utility container. Add `-SkipContainerTest` during rapid local iteration if you only need the verified OCI archive.

Supply `-Platform linux/amd64` or `-Platform linux/arm64` to select a platform explicitly. AMD64 uses Alpine and ARM64 uses Ubuntu 26.04, whose .NET 11 SDK includes PowerShell 7 on ARM64. Use the corresponding package manager when extending either image.

The script accepts `-DocfxVersion` (defaulting to `ARG DOCFX_VERSION` in `Dockerfile`), `-EngineVersion` for the Codebelt engine Semantic Version (without a leading `v` or `+` build metadata), and `-DotnetVersion` for the SDK and runtime used by DocFX. The defaults package DocFX `2.81.0` and the .NET 10 and .NET 11 SDKs. Use `-FrameworkSdkImage` or `-FrameworkSdkArm64Image` to override the final SDK base on the corresponding platform. Keep the base's C library compatible with that platform's SDK stage and ensure the base supplies PowerShell 7. The [framework views compatibility contract](framework-views/README.md#template-compatibility) applies when changing the CLI or template.

To run all PowerShell unit test suites with 100% enforced coverage (covering `framework-views/*.ps1`, `BuildAndPushDocfxImage.ps1`, `tools/DocfxImage.psm1`, and `tools/Invoke-DocfxRelease.ps1`) plus the `.NET 10` OCI artifact test suite (`tests/OciArtifact.Tests.ps1`):

```powershell
pwsh -NoProfile -File ./tools/Invoke-UnitTests.ps1
```

## CI/CD release and deployment lifecycle

Official `codebeltnet/docfx` releases follow a build-once, promote-verified-artifact delivery lifecycle aligned with `codebeltnet/csrun`:

```text
Pull request (.github/workflows/pr.yml)
    -> Required quality gate (unit tests + 100% coverage, native Windows/Linux, browser/routing, Cuemon, native AMD64 & ARM64 containers, workflow lint)
    -> Merge to main
    -> Push vMAJOR.MINOR.PATCH Git release tag (.github/workflows/release.yml)
    -> Run full quality gates & native AMD64/ARM64 OCI builds (.github/workflows/container.yml)
    -> Assemble multi-platform OCI index without rebuilding & verify via OciArtifact.cs + codebeltnet/oci-artifact-verify@v1
    -> Create draft GitHub Release with durable split OCI assets & checksums, then clean transient CI artifacts
    -> Human approves and publishes the GitHub Release (.github/workflows/deploy.yml)
    -> Reconstruct & re-verify durable OCI assets, then promote to Docker Hub via Skopeo (--all --preserve-digests)
    -> Verify all six tags resolve to the exact multi-platform OCI index digest & re-verify downloaded registry content
```

### Workflow segregation

| Workflow | Trigger | Purpose & permissions |
| --- | --- | --- |
| [`.github/workflows/pr.yml`](.github/workflows/pr.yml) | `pull_request` to `main`, `workflow_dispatch` | Runs workflow syntax linting (`actionlint`), `Dockerfile` `ARG DOCFX_VERSION` consistency checks, PowerShell unit tests with 100% coverage + `.NET 10` OCI tests (`ubuntu-26.04` & `windows-2025`), native framework-views regression (`ubuntu-26.04` with NGINX routing & `windows-2025`), Playwright browser & HTTP routing tests, pinned Cuemon acceptance tests, and native AMD64/ARM64 container validation via `container.yml`. Consolidated under **Required quality gate**. Strictly `contents: read`, fork-safe, zero secrets, no large OCI archive uploads. |
| [`.github/workflows/container.yml`](.github/workflows/container.yml) | Reusable (`workflow_call`) | Invoked by both `pr.yml` and `release.yml`. Builds the candidate image once natively on `ubuntu-26.04` (`linux/amd64`) and `ubuntu-26.04-arm` (`linux/arm64`) with SBOM and maximum SLSA provenance, verifies the exported OCI archive, loads it via Skopeo, executes `tests/Test-DocfxContainer.ps1` on native CPU, and verifies `loaded-config` byte equality. Uploads full OCI archives only on tagged release pushes (1-day retention); PR runs upload small JSON metadata only. |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | Push of `v*` tag | Validates strict `vMAJOR.MINOR.PATCH` release tag (authoritative Codebelt engine version without `v`), executes all quality gates and `container.yml`, assembles the exact tested AMD64 & ARM64 manifests into a single multi-platform OCI image index without rebuilding, verifies integrity with `tools/OciArtifact.cs` and `codebeltnet/oci-artifact-verify@v1`, splits assets <= 1 GiB (`docfx.oci.part000`, ...), creates a **draft GitHub Release** with `docfx-release.json` and `docfx.oci.tar.sha256`, verifies durable release asset attachment, and removes transient workflow artifacts. Never touches Docker Hub. |
| [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) | GitHub Release `published`, `workflow_dispatch` | Resolves the approved latest published stable release from `main` (checking tag ancestry on `main` and rejecting drafts, prereleases, or superseded releases), reconstructs and verifies the durable OCI release assets (authoritative `release.yml` run attempt, both native results, checksums, attestations, and `codebeltnet/oci-artifact-verify@v1`), then promotes under the `Production` environment using Skopeo (`--all --preserve-digests`) without rebuilding. Serialized by concurrency group `docfx-production`. |

### Authoritative versioning and promotion safeguards

- **Release tag convention:** Git tags use `vMAJOR.MINOR.PATCH` (for example, `v1.1.0`), which defines Codebelt engine version `1.1.0`. The upstream DocFX CLI version (`2.81.0`) is maintained independently in `Dockerfile` (`ARG DOCFX_VERSION`).
- **Single implementation:** Local builds (`BuildAndPushDocfxImage.ps1`), CI container validation, release assembly, and deployment promotion all share [`tools/DocfxImage.psm1`](tools/DocfxImage.psm1) and [`tools/OciArtifact.cs`](tools/OciArtifact.cs) (a `.NET 10` file-based C# application).
- **Direct-publish safeguard:** `BuildAndPushDocfxImage.ps1 -Publish` intentionally refuses direct `docker buildx build --push` against the official `codebeltnet/docfx` (or `docker.io/codebeltnet/docfx`) repository so production releases cannot bypass build-once native verification and release approval. Custom or fork registries (for example, `-ContainerRegistry localhost:5000/team/`) remain supported for local/fork workflows.
- **Two-phase promotion & conflict protection:** `deploy.yml` preflights all engine-qualified tags (`2.81.0-v1.1.0`, `2.81-v1.1.0`, `2-v1.1.0`) before any registry write. Missing tags are uploaded; tags already pointing to the exact expected OCI index digest are accepted for idempotent retry; any tag pointing to different content fails closed without overwriting. Floating convenience tags (`2.81.0`, `2.81`, `2`) are updated only after all engine-qualified tags exist in the registry with the exact expected digest and after re-confirming the release is still the latest published stable release.
- **Post-publish verification:** After promotion, `deploy.yml` inspects every promoted tag's raw manifest digest to prove no manifest rewriting occurred, then downloads the image by immutable digest (`codebeltnet/docfx@sha256:<index-digest>`) and re-verifies all blobs, both platforms, OCI labels, SPDX SBOM, and SLSA provenance.

### Deployment recovery procedure

To resume or recover a partially completed production deployment of the latest published release:

1. Never rebuild the image or re-tag a release for recovery.
2. In GitHub Actions, manually dispatch **Deploy Docker Hub images** (`.github/workflows/deploy.yml`) from branch `main` with `tag` set to the already-published latest release tag (for example, `v1.1.0`).
3. `deploy.yml` loads deployment tooling from `main` (pinned to a single `deployment-sha`), downloads the original durable OCI assets from the GitHub Release, re-verifies checksums, the authoritative `release.yml` run, native results, and OCI attestations, skips any engine-qualified tag already matching the exact expected index digest, and completes the remaining promotions idempotently.
4. Attempting to dispatch recovery from a non-`main` branch, for a draft/prerelease, or for an older superseded release is automatically rejected to prevent rolling back floating convenience tags (`2`, `2.81`, `2.81.0`).

### Manual GitHub & Docker Hub administrative configuration

Adding workflow YAML files to this repository does **not** automatically configure GitHub environments, secrets, repository rulesets, or Docker Hub policies. Repository administrators must configure the following settings manually before running production deployments:

1. **GitHub Environment (`Production`):**
   - Create an environment named `Production` in `codebeltnet/docfx` (**Settings -> Environments**).
   - Configure required reviewers and restrict deployment branches/tags appropriately.
   - Add the following **environment secrets** (never repository-wide secrets exposed to PRs):
     - `DOCKERHUB_USERNAME` — Docker Hub account username.
     - `DOCKERHUB_TOKEN` — Docker Hub access token scoped strictly to `codebeltnet/docfx`.
2. **Branch Ruleset (`main`):**
   - Update the active `main` branch ruleset to require the consolidated status check **`Required quality gate`** from `.github/workflows/pr.yml`.
3. **Docker Hub Selective Immutable Tags (recommended):**
   - Enable selective immutable-tag rules on `codebeltnet/docfx` for engine-qualified tags using pattern `^.+-v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$` while keeping floating convenience tags movable.

### Inspecting a published release

After a release has been promoted to Docker Hub, inspect any published engine-qualified tag to retrieve the multi-platform image index digest:

```powershell
docker buildx imagetools inspect codebeltnet/docfx:2.81.0-v1.1.0
```

Use the top-level `Digest` field in `codebeltnet/docfx:2.81.0-v1.1.0@sha256:<published-image-index-digest>` for content-addressed immutability. See [Run in the builder image](framework-views/README.md#run-in-the-builder-image) for the consumer command.
