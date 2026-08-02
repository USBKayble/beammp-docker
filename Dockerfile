# syntax=docker/dockerfile:1

FROM debian:12-slim

ARG BEAMMP_VERSION=latest
ARG FRP_VERSION=0.70.1
ARG TARGETARCH

RUN set -eux; \
    ARCH="${TARGETARCH:-amd64}"; \
    if [ "${ARCH}" = "amd64" ]; then ARCH="x86_64"; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates tzdata liblua5.3-0 python3; \
    if [ "${BEAMMP_VERSION}" = "latest" ]; then \
        VERSION="$(curl -fsSL https://api.github.com/repos/BeamMP/BeamMP-Server/releases/latest \
            | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\(.*\)".*/\1/')"; \
    else \
        VERSION="${BEAMMP_VERSION}"; \
    fi; \
    curl -fL -o /usr/local/bin/BeamMP-Server \
        "https://github.com/BeamMP/BeamMP-Server/releases/download/${VERSION}/BeamMP-Server.debian.12.${ARCH}"; \
    chmod +x /usr/local/bin/BeamMP-Server; \
    echo "${VERSION}" > /opt/beammp-version; \
    curl -fL -o /tmp/frp.tar.gz \
        "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${TARGETARCH:-amd64}.tar.gz"; \
    tar -xzf /tmp/frp.tar.gz -C /tmp; \
    cp "/tmp/frp_${FRP_VERSION}_linux_${TARGETARCH:-amd64}/frpc" /usr/local/bin/frpc; \
    chmod +x /usr/local/bin/frpc; \
    rm -rf /tmp/frp*; \
    apt-get purge -y --auto-remove curl; \
    rm -rf /var/lib/apt/lists/*

RUN useradd --system --uid 1000 --create-home beammp \
    && mkdir -p /beammp \
    && chown beammp:beammp /beammp

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY dashboard/ /opt/beammp-dashboard/

USER beammp
WORKDIR /beammp

EXPOSE 30814/tcp 30814/udp 8080/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
