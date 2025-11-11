FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0-alpine

ARG DOCFX_VERSION=2.78.4
ARG DOTNET_VERSION=10.0

ENV DOTNET_ROOT=/root/.dotnet
ENV PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools

RUN apk --no-cache add git bash

RUN git clone https://github.com/dotnet/docfx.git \
    && mkdir -p /opt/docfx

RUN cd docfx \
    && cp -r --parents templates/default /opt/docfx \
    && cp -r --parents templates/modern /opt/docfx

RUN rm -r docfx

RUN curl -sSL --output dotnet-install.sh https://dot.net/v1/dotnet-install.sh \
    && chmod +x ./dotnet-install.sh \
    && ./dotnet-install.sh --runtime aspnetcore --channel ${DOTNET_VERSION}

RUN dotnet tool install --global docfx --version ${DOCFX_VERSION}

RUN mkdir -p /build/docfx/templates \
    && cp -r /opt/docfx/templates /build/docfx/templates

WORKDIR /build
