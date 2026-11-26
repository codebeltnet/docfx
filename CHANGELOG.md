# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - 2026-11-26

This is a patch release that adds destination-aware framework view fallback routing and branded HTTP error pages with client-side recovery, expands unit, container, Playwright, and Cuemon acceptance tests, and enforces the six-tag versioned Docker image policy without `:latest`.

### Added

- Added destination-aware framework view fallback (`framework-views/FrameworkViewConventions.ps1`, `framework-views/Build-DocfxFrameworkViews.ps1`, `framework-views/framework-views.nginx.conf`, and `templates/ms-style/public/framework-view.js`), generating an ordinal-keyed, deduplicated `availability` inventory (`sets` and `pages`) in `framework-views.json`, merging missing API section links into shared root `toc.json` by item name and normalized identity href, routing unavailable HTML pages and directory indexes via NGINX HTTP `302` fallback (stripping `view` parameters while preserving other query parameters and returning HTTP `400` for excess duplicate `view` parameters), and resolving destination-aware links in `framework-view.js` across navigation, search results, and the framework selector,
- Added branded HTTP error pages (`framework-views/DocfxHttpErrors.ps1`, `framework-views/http-error.md.tmpl`, `framework-views/http-error.js`, `framework-views/framework-views.nginx.conf`, `framework-views/Build-DocfxFrameworkViews.ps1`, and `framework-views/FrameworkViewConventions.ps1`), generating static DocFX error pages under `/_docfx-errors/` (reserving `_docfx-errors` in `Get-ApiPath`) for 19 HTTP status codes (`400`–`505`), routing HTML navigation errors to `/_docfx-errors/$status.html` and non-HTML requests to `@docfx_plain_error`, and serving isolated `public/docfx-http-error.js` recovery actions for documentation home, session-history back navigation, search, retry (including fresh `GET` navigation when URLs contain fragments), and `400`/`404` framework availability links,
- Added expanded automated verification (`tests/framework-view/http-error.spec.js`, `tests/framework-view/framework-view.spec.js`, `tests/framework-view/FrameworkViewConventions.Tests.ps1`, `tests/framework-view/Build-DocfxFrameworkViews.Tests.ps1`, `tests/Test-DocfxContainer.ps1`, `tests/framework-view/Test-FrameworkView.ps1`, `tests/framework-view/Test-FrameworkViews.ps1`, `tests/framework-view/cuemon/Build-CuemonFixture.ps1`, `tests/framework-view/cuemon/Test-CuemonFrameworkViews.ps1`, and `tests/framework-view/fixture/`) covering destination-aware fallback, identity-based TOC merging, ordinal page availability keys, and branded HTTP error pages for multi-TFM and single-TFM sites.

### Changed

- Updated repository documentation (`README.md`, `framework-views/README.md`, and `tests/framework-view/README.md`) to cover destination-aware framework view fallback, page availability metadata, shared root TOC merging, branded HTTP error pages, and the expanded browser and Cuemon acceptance tests,
- Updated repository documentation (`README.md`, `framework-views/README.md`, `AGENTS.md`) and delivery tests (`tests/BuildAndPushDocfxImage.Tests.ps1`, `tests/ReleaseDelivery.Tests.ps1`) to document and enforce the six-tag versioned Docker image policy (three floating versioned convenience tags and three Codebelt engine-qualified tags).

### Removed

- Removed `:latest` Docker image tag generation and publication support from `Resolve-DocfxImageTagPlan` (`tools/DocfxImage.psm1`) so local builds, build-only OCI exports, release metadata, and Docker Hub promotions emit only versioned convenience tags (`MAJOR`, `MAJOR.MINOR`, `MAJOR.MINOR.PATCH`) and engine-qualified `-v{EngineVersion}` tags.

## [1.1.0] - 2026-11-25

This is a minor release that refactors native framework views onto convention-based discovery and modular metadata helpers, introduces engine-aware Docker image versioning with OCI metadata labels, establishes an automated build-once GitHub Actions CI/CD release and deployment lifecycle, and adds shared PowerShell 7 and .NET 10 delivery tooling with comprehensive unit and OCI verification suites.

### Added

- Added modular framework-views helpers (`framework-views/FrameworkViewConventions.ps1`, `framework-views/DocfxMetadata.ps1`, and `framework-views/KeepCrossTargetReferences.targets`) providing `.docfx/docfx.json` and `.bot/docfx` defaults, `metadata.dest`-derived API roots, MSBuild-evaluated target framework precedence, ownership-tracked output reuse, metadata caching, and cross-target project reference recovery,
- Added Codebelt engine-aware Docker image versioning (`-EngineVersion`) and build-once OCI export (`-BuildOnly`, `-RequireNative`, `-SkipContainerTest`, `-PassThru`, `-WhatIf`) to `BuildAndPushDocfxImage.ps1`, producing engine-qualified `-v{EngineVersion}` tags (`2-v1.1.0`, `2.81-v1.1.0`, `2.81.0-v1.1.0`) alongside floating convenience tags (`latest`, `2`, `2.81`, `2.81.0`) with strict SemVer and Docker tag validation, prerelease isolation, publish conflict checks, and OCI image metadata labels (`org.opencontainers.image.*`, `net.codebelt.docfx.engine.version`, and `net.codebelt.docfx.cli.version`),
- Added automated GitHub Actions CI/CD workflows (`.github/workflows/pr.yml`, `.github/workflows/container.yml`, `.github/workflows/release.yml`, and `.github/workflows/deploy.yml`) with `.github/actionlint.yaml`, fixed runners (`ubuntu-26.04`, `ubuntu-26.04-arm`, `windows-2025`), Codebelt actions (`codebeltnet/git-checkout@v1`, `codebeltnet/install-dotnet@v3`, `codebeltnet/oci-artifact-verify@v1`), native AMD64/ARM64 OCI export with SBOM and SLSA provenance, multi-platform index assembly and 1 GiB asset splitting into draft GitHub Releases, and release-approved Docker Hub promotion via Skopeo `--all --preserve-digests` with `Production` environment isolation, idempotent recovery, and stale-release protection,
- Added shared PowerShell 7 and `.NET 10` file-based C# delivery tooling (`tools/DocfxImage.psm1`, `tools/OciArtifact.cs`, `tools/Invoke-DocfxRelease.ps1`, and `tools/Invoke-UnitTests.ps1`), repository instructions (`AGENTS.md`), and `.dockerignore`/`.gitignore` rules,
- Added automated Pester 5, OCI, and container verification suites (`tests/BuildAndPushDocfxImage.Tests.ps1`, `tests/ReleaseDelivery.Tests.ps1`, `tests/OciArtifact.Tests.ps1`, `tests/Test-DocfxContainer.ps1`, and `tests/framework-view/Build-DocfxFrameworkViews.Tests.ps1`, `DocfxMetadata.Tests.ps1`, `FrameworkViewConventions.Tests.ps1`) enforcing 100% code coverage across `framework-views/*.ps1`, `BuildAndPushDocfxImage.ps1`, `tools/DocfxImage.psm1`, and `tools/Invoke-DocfxRelease.ps1`.

### Changed

- Refactored `framework-views/Build-DocfxFrameworkViews.ps1` onto `FrameworkViewConventions.ps1` and `DocfxMetadata.ps1`, replacing the mandatory `-SettingsPath` (`framework-views.json`) parameter with `.docfx/docfx.json` and `.bot/docfx` defaults, `metadata.dest`-derived API roots, MSBuild-evaluated framework precedence, StrictMode-safe optional config lookups, and ANSI-stripped metadata diagnostic parsing,
- Updated `Dockerfile` with `ARG DOCFX_VERSION` and standard `org.opencontainers.image.*` and `net.codebelt.docfx.cli.version` image labels,
- Refactored `BuildAndPushDocfxImage.ps1` onto `tools/DocfxImage.psm1` and blocked direct `-Publish` targeting official `codebeltnet/docfx` or `docker.io/codebeltnet/docfx` repositories so production releases cannot bypass the build-once promotion lifecycle,
- Updated `README.md`, `framework-views/README.md`, `templates/ms-style/README.md`, `tests/framework-view/README.md`, and the `tests/framework-view/` integration and Cuemon fixtures (`Test-FrameworkView.ps1`, `Test-FrameworkViews.ps1`, `cuemon/Build-CuemonFixture.ps1`, `fixture/docfx.json`) for convention-based framework views, engine-aware Docker versioning, and the build-once CI/CD release and recovery lifecycle.

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

[1.1.1]: https://github.com/codebeltnet/docfx/compare/v1.1.0..v1.1.1
[1.1.0]: https://github.com/codebeltnet/docfx/compare/v1.0.1..v1.1.0
[1.0.1]: https://github.com/codebeltnet/docfx/compare/v1.0.0..v1.0.1
[1.0.0]: https://github.com/codebeltnet/docfx/compare/v0.1.4..v1.0.0
[0.1.4]: https://github.com/codebeltnet/docfx/compare/v0.1.3..v0.1.4
[0.1.3]: https://github.com/codebeltnet/docfx/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/codebeltnet/docfx/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/codebeltnet/docfx/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/codebeltnet/docfx/releases/tag/v0.1.0
