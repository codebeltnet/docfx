FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine
ARG DOCFX_VERSION=2.75.3
ARG DOTNET_VERSION=8.0

ENV DOTNET_ROOT=/root/.dotnet
ENV PATH=$PATH:$DOTNET_ROOT:$DOTNET_ROOT/tools

RUN apk update --no-cache \
    && apk add --no-cache git \
    && apk add --no-cache bash

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