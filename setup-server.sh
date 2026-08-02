#!/usr/bin/env bash
# setup-server.sh - deploys the BeamMP universal container with the built-in
# frp tunnel. Runs on ANY machine with internet: home PC behind NAT, laptop,
# cloud VM - no port forwarding and no public IP needed. The container's frpc
# connects out to the frps bridge; players join BRIDGE_IP:30814.
#
#     curl -fsSL https://raw.githubusercontent.com/USBKayble/beammp-docker/main/setup-server.sh \
#       | BEAMMP_AUTH_KEY="..." BEAMMP_FRP_SERVER="..." BEAMMP_FRP_TOKEN="..." bash
#
# Required env vars:
#   BEAMMP_AUTH_KEY   free at https://keymaster.beammp.com
#   BEAMMP_FRP_SERVER frps bridge IP/domain (from setup-bridge.sh output)
#   BEAMMP_FRP_TOKEN  shared secret (from setup-bridge.sh output)
#
# Optional env vars (defaults shown):
#   BEAMMP_NAME, BEAMMP_DESCRIPTION, BEAMMP_MAX_PLAYERS, BEAMMP_MAX_CARS,
#   BEAMMP_MAP, BEAMMP_TAGS, BEAMMP_FRP_PORT, BEAMMP_FRP_REMOTE_PORT,
#   IMAGE (container image, default ghcr.io/USBKayble/beammp-docker:latest)
set -euo pipefail

: "${BEAMMP_AUTH_KEY:?BEAMMP_AUTH_KEY is required - free at https://keymaster.beammp.com}"
: "${BEAMMP_FRP_SERVER:?BEAMMP_FRP_SERVER is required - run setup-bridge.sh first}"
: "${BEAMMP_FRP_TOKEN:?BEAMMP_FRP_TOKEN is required - run setup-bridge.sh first}"

IMAGE="${IMAGE:-ghcr.io/USBKayble/beammp-docker:latest}"

# --- runtime detection -------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
    RT=docker
elif command -v podman >/dev/null 2>&1; then
    RT=podman
else
    echo "ERROR: need docker or podman. Install with:" >&2
    echo "  curl -fsSL https://get.docker.com | sh" >&2
    exit 1
fi

# --- volume setup -------------------------------------------------------------
# Resources/ holds mods & scenarios (auto-synced to players). Make sure the
# container user (uid 1000) can write it.
mkdir -p "${PWD}/Resources"
if [ "$(id -u)" = "0" ]; then
    chown 1000:1000 "${PWD}/Resources" 2>/dev/null || true
fi

# Rootless podman maps container uid 1000 to a host subuid, so a plain bind
# mount appears owned by the wrong user (and SELinux blocks the write). Align
# the uids with keep-id and relabel the mount with :Z (both harmless on
# Docker / non-SELinux hosts). Docker ignores these, so guard the flag.
USRNS_FLAG=""
VOL_FLAG=""
if [ "${RT}" = "podman" ]; then
    USRNS_FLAG="--userns=keep-id"
    VOL_FLAG=":Z"
fi

# --- deploy -------------------------------------------------------------------
# Pull only if the image isn't already present locally (re-runs and local
# builds then work offline / without touching the registry).
if ! ${RT} image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "[server] pulling ${IMAGE}"
    ${RT} pull "${IMAGE}"
else
    echo "[server] image ${IMAGE} already present locally"
fi

echo "[server] starting BeamMP with tunnel to ${BEAMMP_FRP_SERVER}"
${RT} rm -f beammp >/dev/null 2>&1 || true
${RT} run -d --name beammp --restart unless-stopped \
    ${USRNS_FLAG} \
    -e BEAMMP_AUTH_KEY="${BEAMMP_AUTH_KEY}" \
    -e BEAMMP_FRP_SERVER="${BEAMMP_FRP_SERVER}" \
    -e BEAMMP_FRP_TOKEN="${BEAMMP_FRP_TOKEN}" \
    -e BEAMMP_NAME="${BEAMMP_NAME:-BeamMP Server}" \
    -e BEAMMP_DESCRIPTION="${BEAMMP_DESCRIPTION:-BeamMP Default Description}" \
    -e BEAMMP_MAX_PLAYERS="${BEAMMP_MAX_PLAYERS:-8}" \
    -e BEAMMP_MAX_CARS="${BEAMMP_MAX_CARS:-1}" \
    -e BEAMMP_MAP="${BEAMMP_MAP:-/levels/gridmap_v2/info.json}" \
    -e BEAMMP_TAGS="${BEAMMP_TAGS:-Freeroam}" \
    -e BEAMMP_FRP_PORT="${BEAMMP_FRP_PORT:-7000}" \
    -e BEAMMP_FRP_REMOTE_PORT="${BEAMMP_FRP_REMOTE_PORT:-30814}" \
    -v "${PWD}/Resources:/beammp/Resources${VOL_FLAG}" \
    "${IMAGE}"

echo "[server] started. Watching logs (Ctrl+C to detach)..."
${RT} logs -f beammp
