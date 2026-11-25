# Repository instructions

## Engineering

- Prioritize correctness, inspect existing code before editing, and preserve compatible working behavior.
- Prefer the smallest safe, reversible change. Match existing naming, structure, and test conventions.
- Prefer PowerShell 7 for orchestration and modern .NET 10 file-based C# applications (`dotnet run --file`) for structured processing and OCI artifact handling. Do not introduce Python dependencies into this repository.
- Maintain `Dockerfile` (`ARG DOCFX_VERSION`) as the single authoritative upstream DocFX CLI version declaration and keep `framework-views/Build-DocfxFrameworkViews.ps1` and `templates/ms-style/framework-views.compat` synchronized with it (`Test-DocfxVersionConsistency`).
- Preserve 100% measured Pester 5 code coverage across `framework-views/*.ps1`, `BuildAndPushDocfxImage.ps1`, `tools/DocfxImage.psm1`, and `tools/Invoke-DocfxRelease.ps1`.
- Validate changes with the relevant executable tests (`./tools/Invoke-UnitTests.ps1`, workflow linting with `actionlint`, and container/framework-view suites as applicable) and report any validation limits honestly.
- Do not push, create tags, create a PR, publish a GitHub release, or publish Docker images without explicit approval.

## GitHub Actions policy

- Prefer Codebelt actions and reusable workflows whenever they support the required behavior:
  - `codebeltnet/git-checkout@v1`
  - `codebeltnet/install-dotnet@v3` (with `versionPrecision: patch`)
  - `codebeltnet/oci-artifact-verify@v1`
- Reference actions and reusable workflows with floating major version tags, not commit SHAs.
- Use external actions only where the Codebelt ecosystem has no suitable equivalent.
- Use explicit, fixed runner labels:
  - `ubuntu-26.04` (Linux AMD64)
  - `ubuntu-26.04-arm` (Linux ARM64)
  - `windows-2025` (Windows)
- Never use floating `ubuntu-latest` or `windows-latest` labels.
- Keep least-privilege permissions (`contents: read` at workflow level; elevate only on the specific job that requires `contents: write` / `actions: write` or `actions: read`).
- Never expose Docker Hub credentials to pull request workflows, release preparation jobs, image layers, artifacts, or logs.

## Delivery lifecycle and versioning

- Follow the build-once, promote-verified-artifact delivery model across four workflows:
  - `.github/workflows/pr.yml` — pull request quality gates (`Required quality gate`), fork-safe without secrets, uploading only lightweight metadata and coverage reports.
  - `.github/workflows/container.yml` — reusable native AMD64 (`ubuntu-26.04`) and ARM64 (`ubuntu-26.04-arm`) builder image construction, OCI export with SBOM and SLSA provenance, native runtime validation, and loaded-config verification.
  - `.github/workflows/release.yml` — triggered on `vMAJOR.MINOR.PATCH` tags (authoritative Codebelt engine version without leading `v`); runs all quality gates, assembles the exact native-verified AMD64/ARM64 manifests into one multi-platform OCI index without rebuilding, verifies via `tools/OciArtifact.cs` and `codebeltnet/oci-artifact-verify@v1`, splits assets <= 1 GiB, creates a draft GitHub Release, verifies durable asset attachment, and cleans transient Actions artifacts.
  - `.github/workflows/deploy.yml` — triggered on GitHub Release `published` (human approval gate) or `workflow_dispatch` from `main` for idempotent recovery; resolves the latest published stable release, validates tag ancestry on `main` and the authoritative `release.yml` run attempt, reconstructs and verifies the exact OCI archive, then promotes it to Docker Hub via Skopeo (`--all --preserve-digests`) under the `Production` environment without rebuilding.
- Engine-qualified tags (`2-v1.1.0`, `2.81-v1.1.0`, `2.81.0-v1.1.0`) are promoted and verified before floating versioned convenience tags (`2`, `2.81`, `2.81.0`); `:latest` is not generated or published. Conflicting engine-qualified tags fail closed; identical index digests allow idempotent recovery; superseded releases are blocked from rolling back floating convenience tags.
- Direct `BuildAndPushDocfxImage.ps1 -Publish` targeting `codebeltnet/docfx` or `docker.io/codebeltnet/docfx` is intentionally disabled so official production releases cannot bypass the build-once promotion lifecycle.
- Distinguish repository-implemented workflow automation from manual GitHub administration (the `Production` environment, required reviewers, `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` environment secrets, `main` ruleset required check `Required quality gate`, and Docker Hub selective immutable-tag rules). Never claim administrative settings are configured unless verified.

## .NET support policy

- Use only .NET 10 and later SDKs and file-based C# apps (`tools/OciArtifact.cs`, `framework-views/Resolve-DocfxProjects.cs`) for repository tooling.
- Keep builder image SDK and DocFX CLI verification aligned with `Dockerfile` (`ARG DOCFX_VERSION`) and the supported .NET 10/11 SDKs packaged in `Dockerfile`.
