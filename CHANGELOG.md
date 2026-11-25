# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-25

This is a minor release that introduces native multi-framework views generation, adds framework-aware selection and search routing to the `ms-style` template, introduces engine-aware Docker image versioning with OCI metadata traceability, establishes an automated build-once CI/CD release and deployment lifecycle aligned with `codebeltnet/csrun`, and updates the builder image and tooling for multi-platform .NET 10/11 and PowerShell 7 support.

### Added

- Added the native multi-framework views generator (`framework-views/Build-DocfxFrameworkViews.ps1`, `FrameworkViewConventions.ps1`, `DocfxMetadata.ps1`, `Resolve-DocfxProjects.cs`, and `KeepCrossTargetReferences.targets`) with `.docfx/docfx.json` and `.bot/docfx` defaults, `metadata.dest`-derived API roots, MSBuild-evaluated framework precedence, ownership-tracked output reuse, metadata caching, and cross-target project reference recovery,
- Added `framework-views/framework-views.nginx.conf` and `framework-views/framework-views.Dockerfile` to route per-framework API pages, xref maps, and search indexes by `?view=` query parameter in a pinned NGINX site image,
- Added framework-view support to the `ms-style` template (`framework-view.js`, `framework-views.compat`, `_master.tmpl`, and `ms-style.css`) with a TOC framework selector, xref-based view fallback, and view-aware search result URLs,
- Added Codebelt engine-aware Docker image versioning (`-EngineVersion`) with `Dockerfile` (`ARG DOCFX_VERSION`) as the single authoritative upstream DocFX CLI version declaration, producing engine-qualified `-v{EngineVersion}` tags (`2-v1.1.0`, `2.81-v1.1.0`, `2.81.0-v1.1.0`) alongside preserved floating convenience tags (`latest`, `2`, `2.81`, `2.81.0`) on a single multi-platform OCI image index with strict SemVer and Docker tag validation, prerelease isolation, conflict checks, and OCI image metadata labels (`org.opencontainers.image.*`, `net.codebelt.docfx.engine.version`, and `net.codebelt.docfx.cli.version`),
- Added automated GitHub Actions CI/CD workflows aligned with `codebeltnet/csrun` using fixed runners (`ubuntu-26.04`, `ubuntu-26.04-arm`, `windows-2025`), Codebelt actions (`codebeltnet/git-checkout@v1`, `codebeltnet/install-dotnet@v3`, `codebeltnet/oci-artifact-verify@v1`), and workflow linting (`.github/actionlint.yaml`): `.github/workflows/pr.yml` (consolidated `Required quality gate`), `.github/workflows/container.yml` (reusable native AMD64/ARM64 build-once container validation), `.github/workflows/release.yml` (tag-triggered multi-platform OCI assembly, verification, splitting, and draft GitHub Release creation), and `.github/workflows/deploy.yml` (release-publication and manual-recovery promotion to Docker Hub via Skopeo `--all --preserve-digests` without rebuilding, with `Production` environment isolation, concurrency control, idempotent retry, and stale-release protection),
- Added shared PowerShell 7 and `.NET 10` file-based C# delivery tooling (`tools/DocfxImage.psm1`, `tools/OciArtifact.cs`, `tools/Invoke-DocfxRelease.ps1`, `tools/Invoke-UnitTests.ps1`, `tests/Test-DocfxContainer.ps1`), repository guidance (`AGENTS.md`), and `.dockerignore`/`.gitignore` hygiene,
- Added comprehensive automated test suites: `tests/BuildAndPushDocfxImage.Tests.ps1` and `tests/ReleaseDelivery.Tests.ps1` with 100% measured Pester coverage across `BuildAndPushDocfxImage.ps1`, `tools/DocfxImage.psm1`, and `tools/Invoke-DocfxRelease.ps1`, `tests/OciArtifact.Tests.ps1` covering real OCI tar verification, SBOM/provenance checks, multi-platform assembly, and split/reassemble integrity, plus the `tests/framework-view/` unit (100% coverage), synthetic/Cuemon integration, and Playwright browser (`@playwright/test` 1.65.1) suites.

### Changed

- Updated `Dockerfile` to base the final builder image on .NET 11 SDK images (`FRAMEWORK_SDK_IMAGE` on `linux/amd64` and `FRAMEWORK_SDK_ARM64_IMAGE` on `linux/arm64`) with PowerShell 7, matching `dotnet-sdk` libc per `TARGETARCH`, `/opt/docfx/framework-views` included, and standard OCI and `net.codebelt.docfx.cli.version` image labels,
- Refactored `BuildAndPushDocfxImage.ps1` onto `tools/DocfxImage.psm1` to share tag planning, version validation, OCI labels, and safeguards between local development and CI, adding `-BuildOnly` (build-once OCI export with SBOM/provenance, verification, Skopeo load, native container testing, and loaded-config digest proof) and `-WhatIf -PassThru` offline planning while blocking direct `-Publish` to official `codebeltnet/docfx` so production releases cannot bypass build-once promotion,
- Updated `README.md`, `framework-views/README.md`, `templates/ms-style/README.md`, and `tests/framework-view/README.md` with CI/CD lifecycle, release/recovery procedures, manual GitHub administrative prerequisites, Docker image versioning contracts, consumer control trade-offs, framework-views setup, and verification instructions.

## [1.0.1] - 2026-09-27

This is a patch release that upgrades DocFX to 2.81.0.

### Changed

- Upgraded DocFX version from 2.80.1 to 2.81.0 in the build script and Docker configuration.

## [1.0.0] - 2026-09-18

This major release introduces the ms-style DocFX template, a Microsoft Learn-styled API reference template with type-first headings and responsive navigation. It includes a multi-stage Docker build optimization, an upgrade to DocFX 2.80.1, floating version tags for flexible Docker image pulling, and comprehensive adoption documentation for consuming repositories.

### Added

- ms-style DocFX template with type-first headings, definition blocks, Learn-like member tables, namespace category tables, responsive navigation rail, and responsive light/dark styling for desktop and mobile screens,
- Multi-stage Docker build with `template-build`, `dotnet-sdk`, and `final` stages to optimize image footprint by retaining only required SDK components in the runtime base,
- Floating version tag support in the build script allowing users to pull images by major version (e.g., `2`), major.minor version (e.g., `2.80`), exact version, or `latest` without tracking individual patch releases,
- Comprehensive adoption documentation for consuming repositories, including template configuration examples, visual alignment with Microsoft Learn, and a curated list of projects already integrated.

### Changed

- Refactored the Dockerfile from a single-stage to a multi-stage pipeline that separates template preparation and SDK tooling installation from the final runtime base, significantly reducing the image footprint,
- Upgraded DocFX version from 2.78.5 to 2.80.1,
- Enhanced repository documentation with detailed ms-style template features, integration guidance for the responsive layout, and improved metadata examples for using `memberLayout: separatePages`.

## [0.1.4] - 2026-02-27

This patch release updates the DocFX version used by the build scripts.

### Changed

- Updated the DocFX version in the build scripts to 2.78.5.

## [0.1.3] - 2025-11-22

This patch release updates dependencies and works around a DocFX compatibility issue.

### Changed

- Updated the project dependencies.

### Fixed

- Added a workaround for [DocFX issue 10900](https://github.com/dotnet/docfx/issues/10900).

## [0.1.2] - 2025-05-25

This patch release updates the documentation and Docker image for DocFX 2.78.x.

### Changed

- Updated the documentation with support notes for DocFX 2.78.x, including an ARM64 compatibility warning for versions 2.78 and later,
- Updated the Docker image to support DocFX 2.78.3.

## [0.1.1] - 2024-08-02

This patch release updates the DocFX version used by the project.

### Changed

- Updated the DocFX version to 2.77.0.

## [0.1.0] - 2024-04-30

This is the initial release of the DocFX builder Docker image.

### Added

- Added a DocFX builder Docker image that includes the default and modern templates,
- Added support for running the DocFX build process in a container.

[1.1.0]: https://github.com/codebeltnet/docfx/compare/v1.0.1..v1.1.0
[1.0.1]: https://github.com/codebeltnet/docfx/compare/v1.0.0..v1.0.1
[1.0.0]: https://github.com/codebeltnet/docfx/compare/v0.1.4..v1.0.0
[0.1.4]: https://github.com/codebeltnet/docfx/compare/v0.1.3..v0.1.4
[0.1.3]: https://github.com/codebeltnet/docfx/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/codebeltnet/docfx/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/codebeltnet/docfx/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/codebeltnet/docfx/releases/tag/v0.1.0
