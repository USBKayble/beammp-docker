# BeamMP Server Docker

Self-hosted [BeamMP](https://beammp.com) server for BeamNG.drive, built by GitHub Actions and published to GHCR.
One image, `linux/amd64` + `linux/arm64` — runs on any VPS or PC with container support. No port forwarding needed
(see Networking).

## Quick start

```bash
docker run -d --name beammp \
  -p 30814:30814/tcp -p 30814:30814/udp \
  -e BEAMMP_AUTH_KEY="your-keymaster-key" \
  -v "$PWD/Resources:/beammp/Resources" \
  ghcr.io/USBKayble/beammp-docker:latest
```

Or with docker-compose (see `docker-compose.yml` for the full annotated version, including networking options).

Prerequisites: a free [BeamMP account + AuthKey](https://keymaster.beammp.com), and every player (including you)
needs BeamNG.drive on Steam + the [BeamMP launcher](https://beammp.com).

## One-command setup (recommended)

Two self-contained scripts deploy everything — no port forwarding, no public IP needed on the server machine.

**1. Bridge** — run once on any machine with a public IP (Oracle free AMD VM, any VPS). Generates a random shared
secret and prints the exact server command with it embedded:

```bash
curl -fsSL https://raw.githubusercontent.com/USBKayble/beammp-docker/main/setup-bridge.sh | bash
```

The output shows the firewall ports to open (7000/tcp, 30814/tcp+udp) and a ready-to-paste one-liner for the server
machine, including `BEAMMP_FRP_SERVER` and `BEAMMP_FRP_TOKEN`.

**2. Server** — run on *any* machine with internet (home PC behind NAT, laptop, cloud VM). Just paste the command the
bridge printed, add your AuthKey:

```bash
curl -fsSL https://raw.githubusercontent.com/USBKayble/beammp-docker/main/setup-server.sh \
  | BEAMMP_AUTH_KEY="your-keymaster-key" \
    BEAMMP_FRP_SERVER="BRIDGE_IP" \
    BEAMMP_FRP_TOKEN="BRIDGE_PRINTED_TOKEN" \
    bash
```

Players join `BRIDGE_IP:30814`. The container's frpc connects *out* to the bridge, so the server host needs nothing
inbound. The secret stays out of the repo — it's generated at bridge setup and only ever printed on your machines.

To update later: re-run the same commands (scripts replace the container with `--restart unless-stopped`).

## Configuration

The server reads the native `BEAMMP_*` environment variables (no config file to render). Full list from the
[BeamMP source](https://github.com/BeamMP/BeamMP-Server/blob/minor/src/Env.cpp):

| Variable | Default | Notes |
|---|---|---|
| `BEAMMP_AUTH_KEY` | *(required)* | Free at https://keymaster.beammp.com. Container exits if unset. |
| `BEAMMP_NAME` | `BeamMP Server` | Name shown to players / in server list |
| `BEAMMP_DESCRIPTION` | `BeamMP Default Description` | |
| `BEAMMP_TAGS` | `Freeroam` | Comma-separated |
| `BEAMMP_PORT` | `30814` | TCP and UDP share this port |
| `BEAMMP_IP` | `::` | Dual-stack all interfaces. Set `0.0.0.0` if IPv6 is disabled on the host |
| `BEAMMP_MAX_PLAYERS` | `8` | |
| `BEAMMP_MAX_CARS` | `1` | Cars per player |
| `BEAMMP_MAP` | `/levels/gridmap_v2/info.json` | Any map you own; see Maps |
| `BEAMMP_PRIVATE` | `true` | `true` = direct-connect only (recommended for friends) |
| `BEAMMP_DEBUG` | `false` | |
| `BEAMMP_LOG_CHAT` | `true` | |
| `BEAMMP_ALLOW_GUESTS` | `true` | Guests play without a BeamMP account |
| `BEAMMP_RESOURCE_FOLDER` | `Resources` | Relative to `/beammp` |
| `BEAMMP_FRP_SERVER` | *(unset)* | frps bridge host/IP. Set to enable the built-in tunnel (see Networking) |
| `BEAMMP_FRP_PORT` | `7000` | frps control port |
| `BEAMMP_FRP_TOKEN` | *(unset)* | Shared secret — must match `auth.token` in the bridge's `frps.toml` |
| `BEAMMP_FRP_REMOTE_PORT` | `30814` | Public port players connect to on the bridge |

Alternatively mount a hand-edited `ServerConfig.toml` at `/beammp/ServerConfig.toml` — env vars take precedence
over the file. Pin a BeamMP version at image build time with the `BEAMMP_VERSION` build arg (default: latest release).

## Mods & scenarios

- **Client mods/maps**: drop `.zip` files into `Resources/Client/` (your mounted volume). The server auto-serves
  them to players on join — nobody installs anything manually.
- **Server plugins**: Lua scripts in `Resources/Server/` — hot-reloadable, for custom rules/scenarios.
- **Maps**: put the map zip in `Resources/Client/`, then set `BEAMMP_MAP` to `/levels/<folder-name>/info.json`
  (the folder name inside the zip's `levels/` directory).
- `docker attach beammp` opens the server console (`reloadmods`, `protectmod`, `kick`, `exit`, ...).

## Networking (no port forwarding needed)

The server needs **both TCP and UDP** 30814 (it binds both on the same port). Two free ways to make it reachable —
the container is identical in both; only the env vars differ.

### Option A — direct (host has a public IP)

If the host already has a public IP (a VPS, a cloud VM, or a home connection with port forwarding), expose
TCP+UDP 30814 and players join `HOST-IP:30814`. No extra config.

### Option B — universal container via an frp bridge (recommended)

The container has **frpc baked in**. Set `BEAMMP_FRP_SERVER` and the container tunnels itself to a public-facing
**frps bridge** — so it works on *any* machine with internet: a home PC behind NAT/CGNAT, a laptop, a container host
with no public IP. No port forwarding, no router access, no public IP needed on the server host. Players always join
`BRIDGE-IP:30814`.

```bash
docker run -d --name beammp \
  -e BEAMMP_AUTH_KEY="your-keymaster-key" \
  -e BEAMMP_FRP_SERVER="BRIDGE_IP" \
  -e BEAMMP_FRP_TOKEN="CHANGE_ME_shared_secret" \
  -v "$PWD/Resources:/beammp/Resources" \
  ghcr.io/USBKayble/beammp-docker:latest
```

Set up the bridge once, on any free machine with a public IP (e.g. an Oracle Cloud free AMD VM — 1/8 core / 1 GB is
plenty for frps):

1. Open the cloud firewall/security list for `7000/tcp` (frp control), `30814/tcp` and `30814/udp` (game).
2. Run the bridge (full annotated config in `bridge/frps.toml`; the `-c` flag is required — the frps image
   entrypoint is bare `/usr/bin/frps` and otherwise ignores the config):
   ```bash
   docker run -d --name frps --restart unless-stopped \
     -p 7000:7000/tcp -p 30814:30814/tcp -p 30814:30814/udp \
     -v "$PWD/frps.toml:/etc/frp/frps.toml:ro" \
     fatedier/frps:v0.70.1 -c /etc/frp/frps.toml
   ```
3. Players join `BRIDGE-IP:30814` — same as if the server were hosted on the bridge.

Notes:
- Keep `BEAMMP_PRIVATE=true` for friends. Public servers register their public IP with BeamMP's backend, which is
  wrong behind a tunnel/NAT.
- Cloudflare Tunnel is TCP-only and Tailscale needs a player-side install, so frp is the free option that works
  for BeamMP. rathole is similar but dormant since 2023.

## Development

```bash
podman build --build-arg BEAMMP_VERSION=v3.9.3 -t beammp-local .
podman run --rm -p 30814:30814/tcp -p 30814:30814/udp -e BEAMMP_AUTH_KEY=... beammp-local
```

`SIGTERM` (e.g. `docker stop`) triggers a graceful shutdown — players are kicked cleanly. Logs go to stdout and
`/beammp/Server.log`. The container runs as non-root (uid 1000).
