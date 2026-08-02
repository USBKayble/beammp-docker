#!/usr/bin/env bash
# setup-bridge.sh - deploys the public-facing frps bridge for the BeamMP
# universal container. Run ONCE on any machine with a public IP (Oracle free
# AMD VM, any VPS, ...). At the end it prints the exact one-liner to run on
# the machine that will host the BeamMP server, token already embedded.
#
#     curl -fsSL https://raw.githubusercontent.com/USBKayble/beammp-docker/main/setup-bridge.sh | bash
#
# Optional env overrides:
#   FRP_TOKEN     shared secret (auto-generated if unset)
#   BRIDGE_IP     public IP/domain to print in the server command
#                 (auto-detected if unset)
#   FRPS_IMAGE    frps image to deploy (default fatedier/frps:v0.70.1)
set -euo pipefail

GITHUB_REPO="USBKayble/beammp-docker"
FRPS_IMAGE="${FRPS_IMAGE:-docker.io/fatedier/frps:v0.70.1}"

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

# --- generate or accept the shared token ------------------------------------
TOKEN="${FRP_TOKEN:-$(head -c 24 /dev/urandom | base64 | tr -d '=+/' | head -c 24)}"

# --- write the frps config ---------------------------------------------------
FRPS_CONF="$(mktemp)"
cat > "${FRPS_CONF}" <<EOF
bindPort = 7000
auth.method = "token"
auth.token = "${TOKEN}"
EOF
chmod 644 "${FRPS_CONF}"

# --- deploy ------------------------------------------------------------------
echo "[bridge] using runtime: ${RT}"
${RT} rm -f frps >/dev/null 2>&1 || true
${RT} run -d --name frps --restart unless-stopped \
    -p 7000:7000/tcp -p 30814:30814/tcp -p 30814:30814/udp \
    -v "${FRPS_CONF}:/etc/frp/frps.toml:ro" \
    ${FRPS_IMAGE} -c /etc/frp/frps.toml >/dev/null

echo "[bridge] waiting for frps to listen..."
for i in $(seq 1 30); do
    if timeout 1 bash -c 'echo > /dev/tcp/localhost/7000' 2>/dev/null; then
        echo "[bridge] frps ready after ${i}s"
        break
    fi
    sleep 1
done

# --- detect public IP ---------------------------------------------------------
PUBLIC_IP="${BRIDGE_IP:-$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo UNKNOWN)}"

cat <<EOF

===============================================================
 frps bridge is UP at ${PUBLIC_IP}:30814 (TCP+UDP)
===============================================================

Firewall (Oracle security list / cloud firewall) must allow INGRESS:
  7000/tcp   frp control channel
  30814/tcp  BeamMP game traffic
  30814/udp  BeamMP game traffic

NOW RUN THIS ON THE MACHINE THAT WILL HOST THE BEAMMP SERVER
(any machine with internet - no port forwarding, no public IP):

  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/setup-server.sh \\
    | BEAMMP_AUTH_KEY="YOUR_KEYMASTER_KEY" \\
      BEAMMP_FRP_SERVER="${PUBLIC_IP}" \\
      BEAMMP_FRP_TOKEN="${TOKEN}" \\
      bash

Players join: ${PUBLIC_IP}:30814
===============================================================
EOF
