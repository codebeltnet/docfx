ARG DOCFX_VERSION=2.81.0
ARG DOTNET_VERSION=10.0
ARG FRAMEWORK_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:11.0-alpine3.24@sha256:52556c0fb9d0f609ae9aeab9efeeba96f4acc2f7038f7696f2235ccbdbb8e290

ARG FRAMEWORK_SDK_ARM64_IMAGE=mcr.microsoft.com/dotnet/sdk:11.0-resolute@sha256:2794448a07118a6eaf00f29ab5d2bf44928517ce5ff86505a63a69230374f599
ARG TARGETARCH

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-alpine AS template-build

ARG DOCFX_VERSION

RUN git clone --depth 1 --branch v${DOCFX_VERSION} https://github.com/dotnet/docfx.git /tmp/docfx \
    && mkdir -p /opt/docfx \
    && cd /tmp/docfx \
    && cp -r --parents templates/default /opt/docfx \
    && cp -r --parents templates/modern /opt/docfx \
    && rm -rf /tmp/docfx

COPY templates/ms-style /opt/docfx/templates/ms-style

# The Alpine SDK omits PowerShell on ARM64. Match both SDKs to the final image's libc.
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-alpine AS dotnet-sdk-amd64
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-resolute AS dotnet-sdk-arm64
FROM dotnet-sdk-${TARGETARCH} AS dotnet-sdk

ARG DOCFX_VERSION

RUN dotnet tool install --global docfx --version ${DOCFX_VERSION}

FROM ${FRAMEWORK_SDK_IMAGE} AS framework-sdk-amd64
FROM ${FRAMEWORK_SDK_ARM64_IMAGE} AS framework-sdk-arm64
FROM framework-sdk-${TARGETARCH} AS final

ENV DOTNET_ROOT=/usr/share/dotnet
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
ENV PATH=$PATH:$DOTNET_ROOT:/root/.dotnet/tools

RUN if command -v apk >/dev/null; then apk --no-cache add git bash libatomic; fi \
    && pwsh -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -ne 7) { exit 1 }'

COPY --from=dotnet-sdk /usr/share/dotnet/sdk /usr/share/dotnet/sdk
COPY --from=dotnet-sdk /usr/share/dotnet/packs /usr/share/dotnet/packs
COPY --from=dotnet-sdk /usr/share/dotnet/sdk-manifests /usr/share/dotnet/sdk-manifests
COPY --from=dotnet-sdk /usr/share/dotnet/templates /usr/share/dotnet/templates
COPY --from=dotnet-sdk /usr/share/dotnet/metadata /usr/share/dotnet/metadata
COPY --from=dotnet-sdk /usr/share/dotnet/shared /usr/share/dotnet/shared
COPY --from=dotnet-sdk /root/.dotnet/tools /root/.dotnet/tools

COPY --from=template-build /opt/docfx/templates /opt/docfx/templates
COPY framework-views /opt/docfx/framework-views

RUN mkdir -p /build/docfx \
    && cp -r /opt/docfx/templates /build/docfx/

ARG DOCFX_VERSION

LABEL org.opencontainers.image.title="Codebelt DocFX Builder" \
      org.opencontainers.image.description="Codebelt DocFX builder image with shared templates and native multi-framework views generator." \
      org.opencontainers.image.url="https://github.com/codebeltnet/docfx" \
      org.opencontainers.image.source="https://github.com/codebeltnet/docfx" \
      org.opencontainers.image.vendor="Codebelt" \
      org.opencontainers.image.licenses="MIT" \
      net.codebelt.docfx.cli.version="${DOCFX_VERSION}"

WORKDIR /build
