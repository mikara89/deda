# -------------------------
# Base runtime for AOT app
# -------------------------
FROM mcr.microsoft.com/dotnet/runtime-deps:10.0 AS base
USER $APP_UID
WORKDIR /app

# -------------------------
# Build stage
# -------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
ARG TARGETRID=linux-x64

WORKDIR /src

# NativeAOT toolchain deps (Debian-based SDK image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    clang zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY ["src/Deda.Host/Deda.Host.csproj", "src/Deda.Host/"]
COPY ["src/Deda.Core/Deda.Core.csproj", "src/Deda.Core/"]
COPY ["src/Deda.Controller/Deda.Controller.csproj", "src/Deda.Controller/"]
COPY ["src/Deda.Triggers.Abstractions/Deda.Triggers.Abstractions.csproj", "src/Deda.Triggers.Abstractions/"]
COPY ["src/Deda.Updates/Deda.Updates.csproj", "src/Deda.Updates/"]
COPY ["src/Deda.HA/Deda.HA.csproj", "src/Deda.HA/"]
COPY ["src/Deda.Observability/Deda.Observability.csproj", "src/Deda.Observability/"]
COPY ["src/Deda.Swarm/Deda.Swarm.csproj", "src/Deda.Swarm/"]
COPY ["src/Deda.Config.Labels/Deda.Config.Labels.csproj", "src/Deda.Config.Labels/"]
COPY ["src/Deda.Triggers.Prometheus/Deda.Triggers.Prometheus.csproj", "src/Deda.Triggers.Prometheus/"]
COPY ["src/Deda.Triggers.RabbitMq/Deda.Triggers.RabbitMq.csproj", "src/Deda.Triggers.RabbitMq/"]
COPY ["src/Deda.Policies/Deda.Policies.csproj", "src/Deda.Policies/"]

RUN dotnet restore "./src/Deda.Host/Deda.Host.csproj" -r $TARGETRID

COPY . .
WORKDIR "/src/src/Deda.Host"

# -------------------------
# Publish (NativeAOT)
# -------------------------
FROM build AS publish
ARG BUILD_CONFIGURATION=Release
ARG TARGETRID=linux-x64

RUN dotnet publish "./Deda.Host.csproj" -c $BUILD_CONFIGURATION -r $TARGETRID -o /app/publish \
    /p:PublishAot=true \
    /p:StripSymbols=true \
    /p:InvariantGlobalization=true \
    /p:UseAppHost=true \
    /p:SelfContained=true

# -------------------------
# Final image runs native binary
# -------------------------
FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish ./

# The published output will contain a native executable named after the project:
# Deda.Host (Linux)
ENTRYPOINT ["./Deda.Host"]
