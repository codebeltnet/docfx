# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/codebeltnet/docfx/compare/v0.1.4..v1.0.0
[0.1.4]: https://github.com/codebeltnet/docfx/compare/v0.1.3..v0.1.4
[0.1.3]: https://github.com/codebeltnet/docfx/compare/v0.1.2..v0.1.3
[0.1.2]: https://github.com/codebeltnet/docfx/compare/v0.1.1..v0.1.2
[0.1.1]: https://github.com/codebeltnet/docfx/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/codebeltnet/docfx/releases/tag/v0.1.0
