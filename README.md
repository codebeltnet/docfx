# DocFX Builder

This repository distributes the DocFX builder image, shared templates and native multi-framework documentation generator.

Use [framework views](framework-views/README.md) to generate one native set of API pages, xrefs and search results per target framework. The same PowerShell entry point runs on Windows, Linux, CI and in the builder image. Ordinary DocFX sites continue to use the standard CLI.

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

## Build the builder image locally

From the repository root, use PowerShell 7 and Docker Buildx in Linux-container mode.

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Tag docfx-local
```

The default loads one platform into Docker and tags it as `docfx-local:2.81.0`, `docfx-local:2.81`, `docfx-local:2`, and `docfx-local:latest`. Supply `-Platform linux/amd64` or `-Platform linux/arm64` to select a platform explicitly. AMD64 uses Alpine and ARM64 uses Ubuntu 26.04, whose .NET 11 SDK includes PowerShell 7 on ARM64. Use the corresponding package manager when extending either image.

The script accepts `-DocfxVersion` for the CLI and upstream templates and `-DotnetVersion` for the SDK and runtime used by DocFX. The defaults package DocFX 2.81.0 and the .NET 10 and .NET 11 SDKs. Use `-FrameworkSdkImage` or `-FrameworkSdkArm64Image` to override the final SDK base on the corresponding platform. Keep the base's C library compatible with that platform's SDK stage and ensure the base supplies PowerShell 7. The [framework views compatibility contract](framework-views/README.md#template-compatibility) applies when changing the CLI or template.

## Publish and verify the builder image

For an authorized release, select a Buildx builder that can build `linux/amd64` and `linux/arm64`, using native nodes or emulation. Use `docker buildx inspect --bootstrap` to check the builder's platforms. If needed, create a builder with `docker buildx create --driver docker-container --name docfx-release --use`. Sign in to the destination registry and run the publishing script from the repository root.

```powershell
pwsh -NoProfile -File ./BuildAndPushDocfxImage.ps1 -Publish
```

Existing release callers must add `-Publish`. The script sends one multi-platform build directly to the registry under the exact, major/minor, major, and `latest` tags. It verifies that all four tags resolve to the built index digest and fetches both required image configs to verify their platforms. On success it prints `codebeltnet/docfx:2.81.0@sha256:<image-index-digest>`. Use `-ContainerRegistry` and `-Tag` for a different registry namespace or repository.

Inspect the exact tag to retrieve the digest and platform list after release.

```powershell
docker buildx imagetools inspect codebeltnet/docfx:2.81.0
```

Use the top-level `Digest` field in `codebeltnet/docfx:2.81.0@sha256:<image-index-digest>`. Record the digest from the approved release alongside the source commit. The version tags can move, including the exact CLI tag when builder content changes. See [Run in the builder image](framework-views/README.md#run-in-the-builder-image) for the consumer command.
