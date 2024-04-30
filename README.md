# DocFX Builder

This repository contains the source code for a Docker image that delegate the DocFX build process to a Docker container.
This way you only need to provide the DocFX metadata and content using a command like `ADD [".", "docfx"]` in your consuming Dockerfile.

An example can be found in the [shared-kernel](https://github.com/codebeltnet/shared-kernel/blob/main/.docfx/Dockerfile.docfx) repository.