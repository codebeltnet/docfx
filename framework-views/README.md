# Native DocFX framework views

`codebeltnet/docfx` owns the generator, MSBuild discovery, framework-aware `ms-style` template, NGINX routing, and generic site image. The [migrated engine and HTTP regression](https://github.com/codebeltnet/docfx-oci-build/tree/c297fe0fb8d428a0b400ebcf888a9ec5ff61105c) retain native DocFX metadata and rendering for each framework.

## Run on Windows or Linux

Use PowerShell 7, Git, DocFX CLI **2.81.0** installed as a .NET tool, and the SDK selected by the consumer's `global.json` or required by its projects. Install .NET 10 or later alongside an older project SDK for the file-based discovery tool. A .NET 11 consumer needs a .NET 11 SDK. The DocFX CLI also needs its .NET 10 runtime. Run from any directory and pass paths to the consumer's configuration, settings, and an empty output directory outside the directory containing `docfx.json`.

```powershell
pwsh -NoProfile -File /path/to/docfx/framework-views/Build-DocfxFrameworkViews.ps1 `
    -DocfxConfig .docfx/docfx.json -SettingsPath .docfx/framework-views.json `
    -OutputRoot .artifacts/framework-views
```

Use the GitHub source archive for an approved **full release commit SHA**. Keep `framework-views/` and `templates/ms-style/` in their original relative layout. The generator uses the template from that distribution by default. For a local development build, point the same command at a DocFX checkout. Install the CLI with `dotnet tool install --tool-path <dir> docfx --version 2.81.0` and put that directory on `PATH`, or install it as a global tool. The generator reads the pinned CLI's file-mapping libraries from its tool store.

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

## Run in the builder image

The existing `codebeltnet/docfx` image distributes the same script and packaging assets at `/opt/docfx/framework-views/` with the matching templates at `/opt/docfx/templates/`. The stock image includes PowerShell and the .NET 10 and .NET 11 SDKs, while the .NET 10 runtime runs DocFX 2.81.0. For other SDK pins, run from the source distribution with the required SDKs on the host or supply them in a derived builder. Keep the generator, CLI and template from the same approved release when possible. The generator binds to the CLI's project mapping API, and the template integrates with that CLI's search worker. A CLI upgrade requires verifying both.

After publication, pin the approved builder as `codebeltnet/docfx:2.81.0@sha256:<image-index-digest>`. Source releases are pinned by full Git commit SHA because the image tag identifies the CLI version. The released digest identifies the exact image contents, including the generator and template. For branch testing, build the existing Dockerfile locally with `docker build -t docfx-framework-views:local /path/to/docfx` and substitute that tag below.

From the consumer root, use a settings file without `builderImage` to run the whole build inside one container. Mount the checkout writable for restore and build outputs.

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

## Migration contract for `docfx-oci-build`

1. Pin one approved `codebeltnet/docfx` full source commit SHA in the action's multi-framework path. Fetch and extract `https://codeload.github.com/codebeltnet/docfx/zip/<full-commit-sha>` into the action's temporary directory, or use an equivalent source checkout pinned to that SHA. Keep the source tree layout. If the consumer specifies `builderImage`, pin the matching published image digest in its settings.
2. When `framework-views` is configured, resolve both consumer input paths against the workspace and call `framework-views/Build-DocfxFrameworkViews.ps1 -DocfxConfig <absolute-config> -SettingsPath <absolute-settings> -OutputRoot <empty-temp-output>`. Put DocFX 2.81.0 on the runner's PATH and ensure the required consumer SDKs are installed. Propagate the exit status. Optional cache inputs may be passed through using the generator's existing switches.
3. Stage `site/` and `nginx.conf` as the primary OCI build context. Resolve the existing `bundled-framework-views` option to `framework-views/framework-views.Dockerfile` in the **same pinned DocFX source**. For a custom Dockerfile, retain the workspace-relative override and the `docfx-source` named context pointing to the directory containing the consumer's `docfx.json`. The manifest travels inside `site/`.
4. Delete the action's copies of the framework generator, resolver, NGINX template, generic Dockerfile and generator regression. Keep action contract tests for pin selection, argument forwarding, Dockerfile selection and staging. For ordinary builds, preserve the current stock DocFX and consumer Dockerfile entry points. Release revision checks, Buildx orchestration, OCI annotations, archive output, checksums and verification remain in the action.

Update any local consumer wrapper that downloads the old action to pin the same DocFX source release. Move framework selection, API path, and assembly-version alignment from direct flags into its settings JSON.

The [regression guide](../tests/framework-view/README.md) covers synthetic projects, SDK pins, the isolated Cuemon fixture, and browser behavior.
