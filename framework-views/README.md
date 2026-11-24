# Native DocFX framework views

`codebeltnet/docfx` provides the generator, MSBuild discovery, framework-aware `ms-style` template, NGINX routing, and generic site image. It runs native DocFX metadata generation and rendering for each framework.

## Run on Windows or Linux

Use PowerShell 7, Git, DocFX CLI **2.81.0** installed as a .NET tool, and the SDK selected by the consumer's `global.json` or required by its projects. Install .NET 10 or later alongside an older project SDK for the file-based discovery tool. A .NET 11 consumer needs a .NET 11 SDK. The DocFX CLI also needs its .NET 10 runtime. Install it with `dotnet tool install --tool-path <dir> docfx --version 2.81.0` and put that directory on `PATH`, or install it as a global tool. The generator reads the CLI's file-mapping libraries from its tool store.

From the consumer root, download the approved source archive by full commit SHA and run the generator. Keep the archive layout so the generator can find `templates/ms-style/`. For local development, set `$distribution` to a DocFX checkout. Use an empty output directory outside the directory containing `docfx.json`.

```powershell
$commit = '<full-release-commit-sha>'
$releaseRoot = Join-Path ([IO.Path]::GetTempPath()) "docfx-source-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $releaseRoot | Out-Null
$archive = Join-Path $releaseRoot 'docfx.zip'
Invoke-WebRequest "https://codeload.github.com/codebeltnet/docfx/zip/$commit" -OutFile $archive
Expand-Archive -LiteralPath $archive -DestinationPath $releaseRoot
$distribution = Join-Path $releaseRoot "docfx-$commit"

pwsh -NoProfile -File "$distribution/framework-views/Build-DocfxFrameworkViews.ps1" `
    -DocfxConfig .docfx/docfx.json -SettingsPath .docfx/framework-views.json `
    -OutputRoot .artifacts/framework-views
```

### Settings

```json
{
  "apiPath": "api",
  "defaultFramework": "net11.0",
  "frameworks": ["net11.0", "net10.0", "netstandard2.1", "netstandard2.0"],
  "alignAssemblyVersion": false
}
```

| Field | Contract |
| --- | --- |
| `apiPath` | Required public API root, without leading or trailing slashes. Every `metadata.dest` must be at or below it, for example `api/dotnet` or `api/extensions/dotnet`. |
| `defaultFramework` | Required declared TFM used for requests without a view. |
| `frameworks` | Optional ordered list of declared TFMs. Include the default. With the field omitted, the default appears first and discovery supplies the rest. View IDs support unqualified `net`, `netstandard`, `netcoreapp`, and compact .NET Framework TFMs. Supply an explicit list of supported TFMs when discovery includes platform-qualified targets. |
| `alignAssemblyVersion` | Optional opt-in for mixed-target project graphs with a common assembly version. For mixed views, a Release build supplies the assembly version to the corresponding metadata group. |
| `templatePath` | Optional path to a compatible `ms-style` override, relative to the settings file or absolute. Use it to test local template changes. |
| `builderImage` | Optional version-and-digest-pinned builder for rendering HTML. Discovery, restore and metadata still run in the calling environment. The image supplies its `ms-style` when `templatePath` is omitted. Its DocFX CLI must report 2.81.0. |

`docfx.json` owns metadata group mappings, exclusions, filters, properties, and destinations. Include `ms-style` in `build.template` and omit the global `TargetFramework` from metadata groups. Keep build content, resources, and consumer template overlays under the configuration directory. Project sources can sit outside it. Omit a site-local entry from `build.xref` if it can resolve UIDs from another view. A project contributes metadata only to its declared targets. Duplicate UIDs within a view have the same constraints as a standard DocFX build.

The generator restores selected projects by default. Use `-NoRestore` when their restore assets already match the build inputs. To reuse metadata, pass `-MetadataCache <directory>` and `-MetadataCacheKey <fingerprint>`. Keep the cache outside the DocFX input directory. The caller's fingerprint must cover the source tree and revision, imported build files, SDK pins and restore inputs, and metadata filters. The generator also hashes its metadata implementation, DocFX config and resolved mappings, selected SDKs, CLI version, and relevant framework settings. Cached metadata is verified for each view. A damaged entry is regenerated independently. `-ForceMetadata` regenerates and refreshes entries. HTML is rendered each time. Use a fresh output directory when retrying a partial build.

### Template compatibility

The generator checks DocFX 2.81.0 and the template root's [`framework-views.compat`](../templates/ms-style/framework-views.compat) marker before discovery. The current marker is `framework-views-v1/docfx-2.81.0`. Pin a full source commit or builder image digest for releases. To test unreleased template changes, set `templatePath` to a working copy that implements the same contract and carries the marker. This check also applies to templates supplied by a rendering image. CLI upgrades require verifying the generator's project mapping APIs and the template's search integration before updating the contract.

## Run in the builder image

The shared builder image distributes the same script and packaging assets at `/opt/docfx/framework-views/` and matching templates at `/opt/docfx/templates/`. It includes PowerShell 7, the .NET 10 and .NET 11 SDKs, and DocFX 2.81.0. The consumer's `global.json` can select an installed project SDK independently of the resolver. For other SDK pins, run from the source distribution with the required SDKs on the host or supply them in a derived builder.

Use the approved image index digest from [Publish and verify the builder image](../README.md#publish-and-verify-the-builder-image). For branch testing, [build the image locally](../README.md#build-the-builder-image-locally) and substitute `docfx-local:2.81.0` below.

From the consumer root, omit `builderImage` from the settings to run discovery, restore, metadata generation, rendering, and site packaging inside one container. Mount the checkout writable for restore and build outputs.

```powershell
$builder = 'codebeltnet/docfx:2.81.0@sha256:<image-index-digest>'
docker run --rm --mount "type=bind,source=$($PWD.Path),target=/workspace" -w /workspace $builder `
    pwsh -NoProfile -File /opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1 `
    -DocfxConfig .docfx/docfx.json -SettingsPath .docfx/framework-views.json `
    -OutputRoot .artifacts/framework-views
```

## Outputs and hosting

- `<OutputRoot>/site/` is the packaged static site. The default view is at the site root. Additional views retain native API HTML, xrefs and search indexes in `_frameworks/<directory>/`. Shared conceptual pages and assets are published once.
- `<OutputRoot>/site/framework-views.json` is the schema-version-1 manifest served at `/framework-views.json`. It contains the API root, default view, framework order, and per-view TFM, directory, xref URL and projects.
- `<OutputRoot>/nginx.conf` serves the public API path and native xref map by exact `?view=` value. Missing or empty view uses the default. Unknown API or xref views receive HTTP 400. Missing pages or slash-terminated directory indexes in a known view receive HTTP 404. The browser selector resolves fallback before navigating. The configuration also serves the view-specific search indexes and keeps physical framework copies internal.
- Per-TFM stage directories and logs are available under the output root for inspection.

Use [framework-views.Dockerfile](framework-views.Dockerfile) with a context containing `site/` and `nginx.conf`. It uses a pinned NGINX base by default, accepts `NGINX_IMAGE` as an explicit build argument, checks for the manifest and runs `nginx -t`. A consumer can provide its own Dockerfile or server configuration and preserve the public path, routing, search worker and cache contract.

```powershell
docker build -f /path/to/docfx/framework-views/framework-views.Dockerfile -t my-docs:local .artifacts/framework-views
docker run --rm -p 127.0.0.1:8080:8080 my-docs:local
```

## OCI action integration

To adopt this distribution for multi-framework builds in the [`docfx-oci-build` action](https://github.com/codebeltnet/docfx-oci-build), pin it by full commit SHA. The action integration resolves the consumer config and settings against its workspace, invokes the generator above with absolute paths and an empty output directory, and propagates its exit status. Optional cache inputs use the same generator switches. Runner prerequisites and optional digest-pinned rendering match the source invocation.

The action stages `site/` and `nginx.conf` as the primary OCI build context. Its `bundled-framework-views` option resolves to `framework-views/framework-views.Dockerfile` from the same pinned source. A custom Dockerfile can use the `docfx-source` named context for the directory containing the consumer's DocFX configuration. The action owns release revision checks, Buildx orchestration, OCI annotations, archive output, checksums, and artifact verification.

The [regression guide](../tests/framework-view/README.md) covers synthetic projects, SDK pins, the isolated Cuemon fixture, and browser behavior.
