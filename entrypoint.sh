#!/bin/bash
set -e

if [ -z "${BEAMMP_AUTH_KEY}" ] \
    && ! grep -q '^[[:space:]]*AuthKey[[:space:]]*=[[:space:]]*"[^"]' /beammp/ServerConfig.toml 2>/dev/null; then
    echo "ERROR: no AuthKey configured." >&2
    echo "Set the BEAMMP_AUTH_KEY environment variable or put an AuthKey in /beammp/ServerConfig.toml." >&2
    echo "Get a free key at https://keymaster.beammp.com" >&2
    exit 1
fi

if [ "${BEAMMP_DASHBOARD}" = "1" ] && [ -z "${BEAMMP_DASHBOARD_PASSWORD}" ]; then
    echo "ERROR: BEAMMP_DASHBOARD=1 requires BEAMMP_DASHBOARD_PASSWORD" >&2
    echo "Set BEAMMP_DASHBOARD_PASSWORD to the login password for the control dashboard." >&2
    exit 1
fi

# The dashboard's config editor writes ServerConfig.toml. But the binary
# re-applies BEAMMP_* env vars over that file at every boot (clobbering edits),
# and only persists env-sourced values into the file after the first run. So
# once the file has a real AuthKey (binary has booted and written its config),
# unset the config env vars: the file becomes authoritative and dashboard
# edits survive restarts. Fresh boots still seed the file from env vars.
if [ "${BEAMMP_DASHBOARD}" = "1" ] \
    && grep -q '^[[:space:]]*AuthKey[[:space:]]*=[[:space:]]*"[^"]' /beammp/ServerConfig.toml 2>/dev/null; then
    unset BEAMMP_NAME BEAMMP_DESCRIPTION BEAMMP_TAGS BEAMMP_PORT BEAMMP_IP \
        BEAMMP_MAX_PLAYERS BEAMMP_MAX_CARS BEAMMP_MAP BEAMMP_PRIVATE \
        BEAMMP_DEBUG BEAMMP_LOG_CHAT BEAMMP_ALLOW_GUESTS BEAMMP_RESOURCE_FOLDER 2>/dev/null || true
    echo "[config] dashboard-managed ServerConfig.toml is authoritative"
fi

# The release binary has no SIGTERM handler. As container PID 1 it would be
# immune to 'docker stop' (the kernel drops default-disposition signals for a
# namespace init). So we stay PID 1, keep the server's console on a FIFO, and
# on SIGTERM/SIGINT feed it the 'exit' command, which is its native graceful
# shutdown (kicks players, fires onShutdown, exits 0).
CONSOLE=/tmp/beammp-console
rm -f "${CONSOLE}"
mkfifo "${CONSOLE}"

GOT_SIGNAL=0
SERVER_SPAWNED=0
shutdown() {
    GOT_SIGNAL=1
    # If SIGTERM lands before the server pipeline spawned (e.g. during the
    # frpc boot wait), delivering 'exit' now is lost: with fd 3 closed and no
    # writer, cat blocks forever on open() and the booting server never reads
    # it. Leave fd 3 alone and let the post-spawn handshake deliver shutdown.
    if [ "${SERVER_SPAWNED}" -eq 1 ]; then
        echo "exit" > "${CONSOLE}" 2>/dev/null || true
        # Drop the hold-open fd so the server's stdin hits EOF: its
        # console-input thread only unblocks on EOF, and shutdown joins it.
        exec 3>&- 2>/dev/null || true
    fi
    trap shutdown_late TERM INT
}
shutdown_late() { :; }
trap shutdown TERM INT

# Hold the FIFO open read-write so cat's open() doesn't block at boot. Both
# pipeline sides must drop it before exec: if the server inherits it, its
# stdin never EOFs and shutdown hangs joining the console-input thread.
exec 3<>"${CONSOLE}"

# Optional tunnel: when BEAMMP_FRP_SERVER is set, the bundled frpc exposes
# this container through a public-facing frps bridge (see README) - no port
# forwarding or public IP needed on this host. frpc must not inherit the
# console FIFO fd (3), or shutdown's EOF handshake would never fire.
# With the control dashboard enabled (BEAMMP_DASHBOARD=1), a third proxy
# tunnels the dashboard's HTTP port so it is reachable at BRIDGE_IP:8080.
FRPC_PID=
if [ -n "${BEAMMP_FRP_SERVER}" ]; then
    FRPC_CONF=/tmp/frpc.toml
    LOCAL_PORT="${BEAMMP_PORT:-30814}"
    REMOTE_PORT="${BEAMMP_FRP_REMOTE_PORT:-${LOCAL_PORT}}"
    DASH_LOCAL_PORT="${BEAMMP_DASHBOARD_PORT:-8080}"
    DASH_REMOTE_PORT="${BEAMMP_DASHBOARD_REMOTE_PORT:-${DASH_LOCAL_PORT}}"
    {
        printf 'serverAddr = "%s"\n' "${BEAMMP_FRP_SERVER}"
        printf 'serverPort = %s\n' "${BEAMMP_FRP_PORT:-7000}"
        # Retry forever when the bridge is unreachable/temporarily down -
        # the server keeps running and the tunnel connects when frps returns.
        printf 'loginFailExit = false\n'
        if [ -n "${BEAMMP_FRP_TOKEN}" ]; then
            printf 'auth.method = "token"\n'
            printf 'auth.token = "%s"\n' "${BEAMMP_FRP_TOKEN}"
        fi
        printf '[[proxies]]\nname = "beammp-tcp"\ntype = "tcp"\n'
        printf 'localIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "${LOCAL_PORT}" "${REMOTE_PORT}"
        printf '[[proxies]]\nname = "beammp-udp"\ntype = "udp"\n'
        printf 'localIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "${LOCAL_PORT}" "${REMOTE_PORT}"
        if [ "${BEAMMP_DASHBOARD}" = "1" ]; then
            printf '[[proxies]]\nname = "beammp-dashboard"\ntype = "tcp"\n'
            printf 'localIP = "127.0.0.1"\nlocalPort = %s\nremotePort = %s\n' "${DASH_LOCAL_PORT}" "${DASH_REMOTE_PORT}"
        fi
    } > "${FRPC_CONF}"
    echo "[frpc] tunneling ${LOCAL_PORT}/tcp+udp via ${BEAMMP_FRP_SERVER}:${BEAMMP_FRP_PORT:-7000} -> port ${REMOTE_PORT}"
    if [ "${BEAMMP_DASHBOARD}" = "1" ]; then
        echo "[frpc] dashboard tunnel ${DASH_LOCAL_PORT} -> ${BEAMMP_FRP_SERVER}:${DASH_REMOTE_PORT}"
    fi
    /usr/local/bin/frpc -c "${FRPC_CONF}" 3>&- &
    FRPC_PID=$!
    sleep 2
    if ! kill -0 "${FRPC_PID}" 2>/dev/null; then
        echo "ERROR: frpc exited immediately - check BEAMMP_FRP_SERVER/TOKEN/REMOTE_PORT" >&2
        wait "${FRPC_PID}" 2>/dev/null || true
        exit 1
    fi
fi

# Optional control dashboard: a stdlib-only Python HTTP server (login-gated)
# that reads Server.log, writes console commands to the FIFO, manages mods in
# Resources/Client, and edits ServerConfig.toml. Must not inherit the console
# FIFO fd (3), same reason as frpc.
DASH_PID=
if [ "${BEAMMP_DASHBOARD}" = "1" ]; then
    echo "[dashboard] starting control dashboard on port ${BEAMMP_DASHBOARD_PORT:-8080}"
    python3 /opt/beammp-dashboard/server.py --port "${BEAMMP_DASHBOARD_PORT:-8080}" 3>&- &
    DASH_PID=$!
    sleep 1
    if ! kill -0 "${DASH_PID}" 2>/dev/null; then
        echo "ERROR: dashboard exited immediately" >&2
        wait "${DASH_PID}" 2>/dev/null || true
        exit 1
    fi
fi

{ exec 3>&-; exec cat "${CONSOLE}"; } | { exec 3>&-; exec /usr/local/bin/BeamMP-Server; } &
SERVER_PID=$!
SERVER_SPAWNED=1

# If a stop landed before the pipeline spawned, its 'exit' was deferred (see
# shutdown()). Wait for the game port to actually listen, then deliver the
# shutdown now that cat is forwarding stdin to the server.
if [ "${GOT_SIGNAL}" -eq 1 ]; then
    GAME_PORT="${BEAMMP_PORT:-30814}"
    for _ in $(seq 1 15); do
        if (exec 3<>"/dev/tcp/127.0.0.1/${GAME_PORT}") 2>/dev/null; then
            break
        fi
        sleep 1
    done
    echo "exit" > "${CONSOLE}" 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
fi

# 'wait' returns 128+N when a trapped signal interrupts it (trap runs after);
# keep waiting until the server really exits and exit with its actual status.
RC=0
while :; do
    if wait "${SERVER_PID}"; then
        RC=0
    else
        RC=$?
    fi
    if [ "${GOT_SIGNAL}" -eq 1 ]; then
        GOT_SIGNAL=0
        continue
    fi
    break
done

# Stop the tunnel child (SIGTERM is frpc's graceful path) and exit with the
# server's status. Never leave frpc running while the container exits.
if [ -n "${FRPC_PID}" ]; then
    kill "${FRPC_PID}" 2>/dev/null || true
    wait "${FRPC_PID}" 2>/dev/null || true
fi
if [ -n "${DASH_PID}" ]; then
    kill "${DASH_PID}" 2>/dev/null || true
    wait "${DASH_PID}" 2>/dev/null || true
fi
exit "${RC}"
