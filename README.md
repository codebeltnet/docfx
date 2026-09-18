# DocFX Builder

This repository contains the source for a Docker image that delegates the DocFX build process to a container.

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

To intentionally use the published shared image, either run `docker pull codebeltnet/docfx:2.78.5` first or build with `--pull`. The `--pull` option refreshes every base image in the consuming Dockerfile, not only the DocFX image.

Static documentation hosts should serve content-hashed assets with a long-lived `immutable` policy and serve stable DocFX URLs with `Cache-Control: no-store`. The `ms-style` page shell also requests same-origin JSON with the Fetch API's `no-store` cache mode. This bypasses navigation data cached before explicit response policies were added; response headers alone cannot invalidate an entry when the browser satisfies the request without contacting the server.

The Cuemon repository contains the proof of concept for this migration on the `v10.7.2/service-update` branch.

The visual target is the .NET API reference surface represented by [Microsoft Learn](https://learn.microsoft.com/en-us/dotnet/api/system.datetime?view=net-10.0).

API source and content conventions are informed by [dotnet-api-docs](https://github.com/dotnet/dotnet-api-docs) and [dotnet/docs](https://github.com/dotnet/docs).

For the underlying template model, see:

- [DocFX template documentation](https://dotnet.github.io/docfx/docs/template.html)
- [Custom-template merge guidance](https://dotnet.github.io/docfx/tutorial/howto_create_custom_template.html)
- [DocFX template CLI reference](https://dotnet.github.io/docfx/reference/docfx-cli-reference/docfx-template.html)

> [!NOTE]
> Something happened with [DocFX](https://github.com/dotnet/docfx) from version 2.78.0 (for ARM64 architecture). Not sure what, but it seems to be solved using `--platform=$BUILDPLATFORM` in the consuming Dockerfile.
>
> For more information, see [What changes were applied to 2.78.x?](https://github.com/dotnet/docfx/discussions/10512).
