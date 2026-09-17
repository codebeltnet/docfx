# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-17

This major release introduces the ms-style DocFX template, which uses type-first headings and a Microsoft Learn-style layout for API reference documentation. It also adds a multi-stage Docker build and guidance for adopting the template in consuming repositories.

### Added

- Added the ms-style DocFX template, with a master layout, class header and member page partials, responsive light and dark styling, type-first headings, definition blocks, and a Microsoft Learn-aligned member layout,
- Added a multi-stage Docker build with `template-build`, `dotnet-sdk`, and `final` stages. The build includes the ms-style template layer to optimize image size,
- Added adoption documentation for the ms-style template, including configuration examples, visual comparisons with Microsoft Learn, and a proof of concept for consuming repositories.

### Changed

- Refactored the Dockerfile into multiple stages so the runtime image retains only the SDK components it needs, reducing the image footprint.

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
