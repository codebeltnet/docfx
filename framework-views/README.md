# Native DocFX framework views

`codebeltnet/docfx` provides the generator, MSBuild discovery, framework-aware `ms-style` template, NGINX routing, and generic site image. It runs native DocFX metadata generation and rendering for each framework.

## Run on Windows or Linux

Use PowerShell 7, Git, DocFX CLI **2.81.0** installed as a .NET tool, and the SDK selected by the consumer's `global.json` or required by its projects. Install .NET 10 or later alongside an older project SDK for the file-based discovery tool. A .NET 11 consumer needs a .NET 11 SDK. The DocFX CLI also needs its .NET 10 runtime. Install it with `dotnet tool install --tool-path <dir> docfx --version 2.81.0` and put that directory on `PATH`, or install it as a global tool. The generator reads the CLI's file-mapping libraries from its tool store.

Run the generator from the consumer repository root. Use the script's installed path if it lives outside the checkout. Keep the distribution layout so the generator can find the bundled template.

```powershell
pwsh -File Build-DocfxFrameworkViews.ps1
```

This reads `.docfx/docfx.json` and writes to `.bot/docfx`, relative to the working directory. Keep `.bot/` covered by the repository's existing ignore convention. CI and isolated builds can specify both paths.

```powershell
pwsh -File Build-DocfxFrameworkViews.ps1 `
    -DocfxConfig .docfx/docfx.json `
    -OutputRoot .bot/docfx
```

An output directory must be dedicated to the generator and start empty. Subsequent invocations reuse the directory, including after a failed build. The generator records the artifacts it owns and refuses to clean a directory with unexpected entries or links. Use a separate directory for persistent metadata caches.

## DocFX configuration and framework precedence

The generator uses the deepest common directory of the `metadata.dest` paths as the public API root. For example, `api/dotnet/runtime` and `api/dotnet/utilities` give `/api/dotnet/`. Use relative, URL-safe destinations under one common API directory. A single metadata group uses its own destination as the API root.

DocFX owns project mappings, filters, exclusions, overwrites and other metadata options. MSBuild supplies each mapped project's evaluated target frameworks, including inherited values. Remove any `TargetFramework` metadata property so the generator can choose the target per view. A project contributes documentation only to its evaluated targets. Unsupported TFMs, including platform-qualified TFMs, fail with the project path and the target in the diagnostic.

The default view is the first discovered target in this order. The same order determines fallback precedence everywhere (hyperlinks, framework selector, and server-side HTTP routing):

1. Modern .NET, by descending numeric version
2. .NET Core, by descending numeric version
3. .NET Standard, by descending numeric version
4. .NET Framework, by descending numeric version

For example, the order is `net11.0`, `net10.0`, `netstandard2.1`, `netstandard2.0`, `net481`, `net48`, `net462`. New unqualified versions follow the same rules when the installed SDK and DocFX support them.

The selected framework is treated as a preference rather than an unconditional routing constraint:

- Whenever a destination API page exists in the requested framework, that framework is preserved.
- Whenever a destination API page does not exist in the requested framework, resolution selects the first framework in precedence order that contains the destination (whether that target is the default framework or a non-default framework).
- Pages that do not exist in any framework return HTTP 404, and unknown framework identifiers return HTTP 400.

Keep build content, resources, and consumer template overlays under the configuration directory. Project sources can sit outside it. Omit a site-local entry from `build.xref` if it can resolve UIDs from another view. Duplicate UIDs within a view have the same constraints as a standard DocFX build.

### Metadata generation and caching

The generator restores selected projects by default. Use `-NoRestore` when their restore assets already match the build inputs. If DocFX reports an unresolved project reference and MSBuild confirms a cross-target reference, the generator builds the affected project and retries with MSBuild's selected dependency DLL. This avoids duplicate assembly identities from Roslyn's design-time builds while retaining each assembly's own version. The retry requires an unused `CustomAfterMicrosoftCommonTargets` or `CustomBeforeMicrosoftCommonTargets` MSBuild extension point for the affected metadata group. For a diagnosed same-target reference with SDK reference assemblies disabled, DocFX can retry in reference-assembly mode without a recovery build.

An unresolved project reference fails generation when recovery is unavailable or when the retry still reports the warning. The error points to the metadata logs. A view's metadata enters the cache only after validation succeeds. Other DocFX warnings remain non-fatal.

To reuse metadata, pass `-MetadataCache <directory>` and `-MetadataCacheKey <fingerprint>`. The caller's fingerprint must cover source files and revision, imported build files, SDK pins, restore inputs and metadata filters. The generator also hashes its metadata implementation, DocFX config, resolved mappings, SDK versions and discovered framework order. It validates each cached view and regenerates a damaged entry independently. Use `-ForceMetadata` to refresh entries. HTML is rendered on every invocation.

### Template compatibility

Include `templates/ms-style` in the DocFX `build.template` list. The generator uses an existing compatible `ms-style` directory at the configured path, or the bundled template when the conventional entry is absent from the checkout. Other template entries stay in the authored order. DocFX must report 2.81.0, and the template's [`framework-views.compat`](../templates/ms-style/framework-views.compat) marker must read `framework-views-v1/docfx-2.81.0`. CLI upgrades require checking the project mapping APIs and the template's search integration.

## Run in the builder image

The shared builder image distributes the same script and packaging assets at `/opt/docfx/framework-views/` and matching templates at `/opt/docfx/templates/`. It includes PowerShell 7, the .NET 10 and .NET 11 SDKs, and DocFX 2.81.0. The consumer's `global.json` can select an installed project SDK independently of the resolver. For other SDK pins, run from the source distribution with the required SDKs on the host or supply them in a derived builder.

Use the approved image index digest from the [CI/CD release and deployment lifecycle](../README.md#cicd-release-and-deployment-lifecycle). See [Docker image versioning](../README.md#docker-image-versioning) for the trade-offs between versioned convenience tags (`codebeltnet/docfx:2`, `:2.81`, `:2.81.0`), engine-qualified tags (`:2-v1.1.0`, `:2.81-v1.1.0`, `:2.81.0-v1.1.0`), and digest-pinned references; `:latest` is not published or supported, while versioned convenience-tag references remain supported. The `1.1.0` example below illustrates the naming contract and is not publicly available until release publication occurs. For branch testing, [build the image locally](../README.md#build-the-builder-image-locally) with `-Tag docfx-local -EngineVersion 1.1.0` and substitute `docfx-local:2.81.0-v1.1.0` (or `docfx-local:2.81.0`) below.

Run the entire generator in the selected image. Mount the consumer checkout writable for restore and build outputs.

```powershell
$builder = 'codebeltnet/docfx:2.81.0-v1.1.0@sha256:<published-image-index-digest>'
docker run --rm --mount "type=bind,source=$($PWD.Path),target=/workspace" -w /workspace $builder `
    pwsh -NoProfile -File /opt/docfx/framework-views/Build-DocfxFrameworkViews.ps1
```

## Outputs and hosting

- `<OutputRoot>/site/` is the packaged static site. The default view is at the site root. Additional views retain native API HTML, xrefs and search indexes in `_frameworks/<directory>/`. Shared conceptual pages and assets are published once. When shared root navigation (`toc.json`) references an API section absent from the default view, the generator merges its resolved HTML link from the first view in precedence order where it exists.
- `<OutputRoot>/site/framework-views.json` is the schema-version-1 manifest served at `/framework-views.json`. It contains the API root, default view, framework order, per-view TFM, directory, xref URL and projects, and a compact deduplicated `availability` inventory (`sets` and `pages`) derived from the actual generated native DocFX HTML output.
- `<OutputRoot>/nginx.conf` serves the public API path and native xref map by exact `?view=` value. Missing or empty view uses the default. Unknown API or xref views (or excess duplicate `view` parameters) receive HTTP 400. For HTML pages and `/`-terminated directory indexes under the API root that are unavailable in the requested view, NGINX checks the generated framework directories in precedence order and responds with HTTP 302 to the resolved public URL (`?view=<resolved>`), preserving unrelated query parameters while browsers preserve fragments. Pages missing from all views, non-HTML API resources (such as view-isolated `toc.json` files or missing static files), and direct requests under `/_frameworks/` receive HTTP 404 without redirecting. The configuration also serves view-specific search indexes and keeps physical framework copies internal.
- The `ms-style` client script (`public/framework-view.js`) applies the same destination-aware resolution policy across global navigation, TOCs, breadcrumbs, cross-references, search results, ordinary internal API hyperlinks, and the framework selector. Resolved `href` attributes are written directly to anchors so opening links in new tabs works natively without click interception. Single-framework DocFX builds omit `_frameworkApi` and keep standard native behavior.
- Per-TFM stage directories and logs are available under the output root for inspection.

Use [framework-views.Dockerfile](framework-views.Dockerfile) with a context containing `site/` and `nginx.conf`. It uses a pinned NGINX base by default, accepts `NGINX_IMAGE` as an explicit build argument, checks for the manifest and runs `nginx -t`. A consumer can provide its own Dockerfile or server configuration and preserve the public path, routing, search worker and cache contract.

```powershell
docker build -f /path/to/docfx/framework-views/framework-views.Dockerfile -t my-docs:local .bot/docfx
docker run --rm -p 127.0.0.1:8080:8080 my-docs:local
```

### HTTP error pages

The generator renders branded error documents with the site's configured DocFX templates and packages them under the internal `/_docfx-errors/` directory. The generated NGINX configuration serves them automatically for document requests, even when the build has only one target framework. It keeps the original HTTP status and serves a short response for missing assets and other non-document requests. The error documents are excluded from the search index.

The error page provides a documentation home link and expandable HTTP status details without JavaScript. With JavaScript, it shows the requested path, uses the site's saved theme, and offers the existing DocFX search when available. **Go back** checks the last successful documentation page recorded for the browser tab and falls back to the documentation home. The session record keeps the path and applicable framework view. **Retry** opens the original URL with a fresh GET for transient server errors.

The usual automatic framework fallback takes precedence. If a request still fails and the framework inventory identifies that API page, the error page can show the selected framework and link to the available views in engine order. It checks that each destination responds directly before offering it and marks the default when available. Missing framework metadata leaves the standard recovery actions available.

The feature applies to errors handled by the documentation site's generated NGINX configuration. When NGINX closes a timed-out connection before sending an HTTP response, the browser handles the connection failure. Sites built with the standard DocFX CLI and served through their own configuration use their host's error handling. Cloudflare, ingress controllers, load balancers and unavailable containers can respond before the request reaches the documentation server and control their own error pages.

## OCI action integration

Use an updated action and compatible builder image. Pin the action by full release commit SHA. Add these inputs alongside the existing version, revision and output inputs. [DocFX OCI build action](https://github.com/codebeltnet/docfx-oci-build)

```yaml
with:
  docfx-config: .docfx/docfx.json
  framework-views: true
```

The action runs the bundled generator inside the builder image and stages the generated `site/` and `nginx.conf` as the OCI build context. It selects the bundled `framework-views.Dockerfile` by default. An explicit workspace-relative `dockerfile` overrides packaging and can use the named `docfx-source` build context for authored DocFX files. The action owns revision checks, Buildx orchestration, OCI annotations, archive output, checksums, and artifact verification. Omitting the opt-in or setting it to `false` uses ordinary DocFX.

## Migrate existing framework views

1. Remove the authored framework settings file and its command-line argument. Keep the generated runtime manifest in the packaged site.
2. Use the existing DocFX destinations to establish a common API directory. Review the default view and fallback order if they were previously set by hand.
3. Run locally with the defaults or pass explicit configuration and output paths in CI. Point packaging at the new output directory.
4. In the OCI action, change the settings-file input to `framework-views: true`. Omit the Dockerfile input for bundled packaging, or retain the path to a custom Dockerfile. Update the action and its builder image together.

The [regression guide](../tests/framework-view/README.md) covers the synthetic projects, SDK pins, Cuemon fixture, and browser behavior.
