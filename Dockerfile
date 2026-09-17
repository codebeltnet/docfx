ARG DOCFX_VERSION=2.78.5
ARG DOTNET_VERSION=10.0

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-alpine AS template-build

ARG DOCFX_VERSION

RUN git clone --depth 1 --branch v${DOCFX_VERSION} https://github.com/dotnet/docfx.git /tmp/docfx \
    && mkdir -p /opt/docfx \
    && cd /tmp/docfx \
    && cp -r --parents templates/default /opt/docfx \
    && cp -r --parents templates/modern /opt/docfx \
    && rm -rf /tmp/docfx

COPY templates/ms-style /opt/docfx/templates/ms-style

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:${DOTNET_VERSION}-alpine AS dotnet-sdk

ARG DOCFX_VERSION

RUN dotnet tool install --global docfx --version ${DOCFX_VERSION}

# DocFX metadata builds can use MSBuild, so retain the SDK on the smaller runtime base.
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/aspnet:${DOTNET_VERSION}-alpine AS final

ENV DOTNET_ROOT=/usr/share/dotnet
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
ENV PATH=$PATH:$DOTNET_ROOT:/root/.dotnet/tools

RUN apk --no-cache add git bash libatomic

COPY --from=dotnet-sdk /usr/share/dotnet/sdk /usr/share/dotnet/sdk
COPY --from=dotnet-sdk /usr/share/dotnet/packs /usr/share/dotnet/packs
COPY --from=dotnet-sdk /usr/share/dotnet/sdk-manifests /usr/share/dotnet/sdk-manifests
COPY --from=dotnet-sdk /usr/share/dotnet/templates /usr/share/dotnet/templates
COPY --from=dotnet-sdk /usr/share/dotnet/metadata /usr/share/dotnet/metadata
COPY --from=dotnet-sdk /root/.dotnet/tools /root/.dotnet/tools

COPY --from=template-build /opt/docfx/templates /opt/docfx/templates

RUN mkdir -p /build/docfx \
    && cp -r /opt/docfx/templates /build/docfx/

WORKDIR /build
