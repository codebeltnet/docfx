# DocFX Builder

This repository contains the source code for a Docker image that delegate the DocFX build process to a Docker container.
This way you only need to provide the DocFX metadata and content using a command like `ADD [".", "docfx"]` in your consuming Dockerfile.

An example can be found in the [shared-kernel](https://github.com/codebeltnet/shared-kernel/blob/main/.docfx/Dockerfile.docfx) repository.

> [!NOTE]
> Something happened with [DocFX](https://github.com/dotnet/docfx) from version 2.78.0 (for ARM64 architecture). Not sure what, but it seems to be solved using `--platform=$BUILDPLATFORM` in the consuming Dockerfile.
> 
> For more information check out this discussion: [What changes was applied to 2.78.x?](https://github.com/dotnet/docfx/discussions/10512)
