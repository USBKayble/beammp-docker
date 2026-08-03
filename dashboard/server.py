#!/usr/bin/env python3
"""BeamMP control dashboard - stdlib-only HTTP server.

Runs inside the universal BeamMP container (spawned by entrypoint.sh when
BEAMMP_DASHBOARD=1). Login-gated; serves a static SPA and a small JSON API:

  POST /api/login    {password} -> sets session cookie
  GET  /api/status   server state, players, log tail
  GET  /api/config   ServerConfig.toml [General] fields
  POST /api/config   partial field update (persists to ServerConfig.toml)
  POST /api/console  {command} -> written to the server console FIFO
  POST /api/restart  graceful server restart (container restart policy boots it back)
  GET  /api/mods     list Resources/Client mods
  POST /api/mods     multipart upload to Resources/Client
  DELETE /api/mods?name=  delete a mod
  GET  /api/maps     maps discoverable from Resources/Client

Security: all /api/* except /api/login require a session cookie; sessions are
in-memory tokens with expiry; mod filenames are basename-constrained.
"""

import argparse
import email.parser
import hashlib
import json
import os
import re
import secrets
import socket
import stat
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BEAMMP_DIR = Path("/beammp")
CONFIG_FILE = BEAMMP_DIR / "ServerConfig.toml"
LOG_FILE = BEAMMP_DIR / "Server.log"
RESOURCES_DIR = BEAMMP_DIR / "Resources"
CLIENT_MODS_DIR = RESOURCES_DIR / "Client"
CONSOLE_FIFO = Path("/tmp/beammp-console")
VERSION_FILE = Path("/opt/beammp-version")
STATIC_DIR = Path(__file__).resolve().parent / "static"

SESSION_TTL_SECONDS = 12 * 3600
LOG_TAIL_LINES = 50
MOD_EXTENSIONS = (".zip", ".crp", ".json")

CONFIG_EDITABLE = {
    "name": "Name",
    "description": "Description",
    "tags": "Tags",
    "map": "Map",
    "maxPlayers": "MaxPlayers",
    "maxCars": "MaxCars",
    "private": "Private",
    "allowGuests": "AllowGuests",
    "logChat": "LogChat",
    "port": "Port",
}

_CFG_VALUE = re.compile(r'^(\s*)([A-Za-z][A-Za-z0-9]*)(\s*=\s*)(.*)$')
_CFG_BOOL = re.compile(r'^(true|false)$', re.IGNORECASE)


def now():
    return time.time()


class SessionStore:
    def __init__(self):
        self._tokens = {}

    def create(self):
        token = secrets.token_urlsafe(32)
        self._tokens[token] = now() + SESSION_TTL_SECONDS
        return token

    def valid(self, token):
        if token not in self._tokens:
            return False
        if self._tokens[token] < now():
            del self._tokens[token]
            return False
        return True

    def destroy(self, token):
        self._tokens.pop(token, None)


SESSIONS = SessionStore()


def required_password():
    pw = os.environ.get("BEAMMP_DASHBOARD_PASSWORD", "")
    if not pw:
        raise RuntimeError("BEAMMP_DASHBOARD_PASSWORD is not set")
    return pw


def game_port():
    return int(os.environ.get("BEAMMP_PORT", "30814"))


def version():
    try:
        return VERSION_FILE.read_text().strip()
    except OSError:
        return "unknown"


def server_online():
    try:
        with socket.create_connection(("127.0.0.1", game_port()), timeout=1.0):
            return True
    except OSError:
        return False


def read_config():
    result = {k: None for k in CONFIG_EDITABLE}
    result["authKeySet"] = False
    try:
        lines = CONFIG_FILE.read_text().splitlines()
    except OSError:
        return result
    in_general = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_general = stripped == "[General]"
            continue
        if not in_general or "=" not in line:
            continue
        m = _CFG_VALUE.match(line)
        if not m:
            continue
        key, value = m.group(2), m.group(4).strip()
        if key == "AuthKey":
            result["authKeySet"] = bool(re.match(r'^"[^"]+"$', value))
            continue
        for field, cfg_key in CONFIG_EDITABLE.items():
            if cfg_key == key:
                result[field] = parse_toml_value(value)
    return result


def parse_toml_value(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        return raw[1:-1]
    if _CFG_BOOL.match(raw):
        return raw.lower() == "true"
    try:
        return int(raw)
    except ValueError:
        return raw


def format_toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return '"{}"'.format(str(value).replace('"', '\\"'))


def write_config(updates):
    """Line-based in-place update of [General] keys, preserving everything else."""
    updates = {k: v for k, v in updates.items() if k in CONFIG_EDITABLE}
    if not updates:
        return False
    try:
        lines = CONFIG_FILE.read_text().splitlines(keepends=True)
    except OSError:
        lines = []
    if not lines:
        lines = ["[General]\n"]
    in_general = False
    changed = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_general = stripped == "[General]"
            new_lines.append(line)
            continue
        m = _CFG_VALUE.match(line.rstrip("\n"))
        if in_general and m and m.group(2) in CONFIG_EDITABLE.values():
            field = next(f for f, k in CONFIG_EDITABLE.items() if k == m.group(2))
            if field in updates:
                value = format_toml_value(updates[field])
                indent = m.group(1)
                new_lines.append(f"{indent}{m.group(2)}{m.group(3)}{value}\n")
                changed.add(field)
                continue
        new_lines.append(line)
    for field, value in updates.items():
        if field not in changed:
            cfg_key = CONFIG_EDITABLE[field]
            if in_general:
                new_lines.append(f"{cfg_key} = {format_toml_value(value)}\n")
            else:
                new_lines.append(f"\n[General]\n{cfg_key} = {format_toml_value(value)}\n")
                in_general = True
    CONFIG_FILE.write_text("".join(new_lines))
    return True


def tail_log(lines=LOG_TAIL_LINES):
    try:
        raw = LOG_FILE.read_bytes()
    except OSError:
        return []
    text = raw.decode("utf-8", errors="replace")
    return text.splitlines()[-lines:]


_LOG_TIME = re.compile(r'^\[(\d{2})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})\]')
_STARTED = "ALL SYSTEMS STARTED SUCCESSFULLY"


def last_start_epoch():
    try:
        raw = LOG_FILE.read_bytes()
    except OSError:
        return None
    found = None
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if _STARTED in line:
            m = _LOG_TIME.match(line)
            if m:
                found = parse_log_time(m.group(1), m.group(2), m.group(3),
                                       m.group(4), m.group(5), m.group(6))
    return found


def parse_log_time(mo, dy, yr, hh, mm, ss):
    year = 2000 + int(yr)
    try:
        return time.mktime(time.struct_time(
            (year, int(mo), int(dy), int(hh), int(mm), int(ss), 0, 0, -1)))
    except (ValueError, OverflowError):
        return None


# BeamMP real log formats (v3.9.x, from the BeamMP-Server source):
#   join complete : "[INFO] <name> : Connected"
#   id assignment : "[INFO] Assigned ID <n> to <name>"
#   leave         : "[INFO] <name> Connection Terminated"
# In Debug mode a "(<id>) \"<name>\"" context prefix precedes the level, but
# the trailing "<name> : Connected" / "<name> Connection Terminated" still
# holds regardless, so these regexes work in both log modes.
_JOIN_COMPLETE = re.compile(r'\[INFO\]\s+(.+?)\s*:\s*Connected$')
_LEAVE = re.compile(r'\[INFO\]\s+(.+?)\s+Connection[\s_]Terminated$')
_ASSIGN_ID = re.compile(r'\[INFO\]\s+Assigned ID\s+(\d+)\s+to\s+(.+?)\s*$')


def players_from_log():
    """Reconstruct the current player roster by replaying join/leave events
    since the last clean server start. BeamMP logs a join-complete line
    (\"<name> : Connected\") and a leave line (\"<name> Connection
    Terminated\"); player IDs come from the \"Assigned ID\" handshake line."""
    try:
        raw = LOG_FILE.read_bytes()
    except OSError:
        return []
    lines = raw.decode("utf-8", errors="replace").splitlines()
    start = 0
    for i, line in enumerate(lines):
        if _STARTED in line:
            start = i + 1
    roster = {}
    name_to_id = {}
    for line in lines[start:]:
        am = _ASSIGN_ID.search(line)
        if am:
            name = am.group(2).strip()
            name_to_id[name] = am.group(1)
        jm = _JOIN_COMPLETE.search(line)
        if jm:
            name = jm.group(1).strip()
            roster[name] = {
                "name": name,
                "id": name_to_id.get(name, ""),
                "joinTime": time.time(),
            }
        lm = _LEAVE.search(line)
        if lm:
            roster.pop(lm.group(1).strip(), None)
    return sorted(roster.values(), key=lambda p: p["joinTime"])


def write_console(command):
    command = command.strip()
    if not command:
        return False, "empty command"
    if not CONSOLE_FIFO.exists():
        return False, "console not available (server not started)"
    try:
        fd = os.open(str(CONSOLE_FIFO), os.O_WRONLY | os.O_NONBLOCK)
    except OSError as exc:
        return False, f"cannot open console: {exc.strerror}"
    try:
        os.write(fd, (command + "\n").encode())
    except OSError as exc:
        return False, f"cannot write console: {exc.strerror}"
    finally:
        os.close(fd)
    return True, ""


def list_mods():
    try:
        entries = sorted(CLIENT_MODS_DIR.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        return []
    mods = []
    for path in entries:
        if not path.is_file():
            continue
        st = path.stat()
        mods.append({
            "name": path.name,
            "size": st.st_size,
            "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)),
        })
    return mods


def save_mod(filename, data):
    safe = os.path.basename(filename)
    if not safe or safe in (".", "..") or "/" in safe or "\\" in safe:
        return False, "invalid filename"
    if not safe.lower().endswith(MOD_EXTENSIONS):
        return False, "only .zip, .crp, .json files are allowed"
    CLIENT_MODS_DIR.mkdir(parents=True, exist_ok=True)
    target = CLIENT_MODS_DIR / safe
    target.write_bytes(data)
    return True, safe


def delete_mod(filename):
    safe = os.path.basename(filename)
    if not safe or safe in (".", ".."):
        return False, "invalid filename"
    target = CLIENT_MODS_DIR / safe
    if not target.is_file():
        return False, "not found"
    target.unlink()
    return True, safe


def discover_maps():
    """Known server map paths: default gridmap_v2 plus any zip in
    Resources/Client that carries a levels/<name>/info.json entry."""
    maps = [{"label": "Gridmap v2 (default)", "path": "/levels/gridmap_v2/info.json"}]
    try:
        entries = sorted(CLIENT_MODS_DIR.iterdir(), key=lambda p: p.name.lower())
    except OSError:
        entries = []
    import zipfile
    for path in entries:
        if path.suffix.lower() != ".zip":
            continue
        try:
            with zipfile.ZipFile(path) as zf:
                for name in zf.namelist():
                    m = re.match(r'^levels/([^/]+)/info\.json$', name)
                    if m:
                        maps.append({
                            "label": f"{m.group(1)} ({path.name})",
                            "path": f"/levels/{m.group(1)}/info.json",
                        })
                        break
        except (zipfile.BadZipFile, OSError):
            continue
    seen, dedup = set(), []
    for item in maps:
        if item["path"] not in seen:
            seen.add(item["path"])
            dedup.append(item)
    return dedup


def status_payload():
    cfg = read_config()
    players = players_from_log()
    started = last_start_epoch()
    return {
        "online": server_online(),
        "name": cfg.get("name") or "BeamMP Server",
        "description": cfg.get("description") or "",
        "map": cfg.get("map") or "/levels/gridmap_v2/info.json",
        "maxPlayers": cfg.get("maxPlayers") or 8,
        "maxCars": cfg.get("maxCars") or 1,
        "private": bool(cfg.get("private")),
        "tags": cfg.get("tags") or "",
        "players": players,
        "playerCount": len(players),
        "uptimeSec": int(now() - started) if started else None,
        "startedAt": time.strftime("%Y-%m-%d %H:%M:%S",
                                   time.localtime(started)) if started else None,
        "version": version(),
        "logLines": tail_log(),
    }


def parse_body(handler, max_bytes=10 * 1024 * 1024):
    length = int(handler.headers.get("Content-Length", "0") or 0)
    if length > max_bytes:
        return None
    return handler.rfile.read(length)


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "BeamMPDashboard/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # -- helpers -------------------------------------------------------------

    def _send(self, status, body, content_type="application/json", extra=None):
        payload = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    def _json(self, status, obj, extra=None):
        self._send(status, obj, extra=extra)

    def _ok(self, obj=None):
        self._json(200, obj if obj is not None else {"ok": True})

    def _err(self, status, message):
        self._json(status, {"error": message})

    def _session_token(self):
        cookie = self.headers.get("Cookie", "")
        for part in cookie.split(";"):
            part = part.strip()
            if part.startswith("beammp_session="):
                return part[len("beammp_session="):]
        return None

    def _authorized(self):
        token = self._session_token()
        return bool(token and SESSIONS.valid(token))

    # -- routing -------------------------------------------------------------

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/status":
            self._require_auth(lambda: self._json(200, status_payload()))
        elif path == "/api/config":
            self._require_auth(lambda: self._json(200, read_config()))
        elif path == "/api/mods":
            self._require_auth(lambda: self._json(200, {"mods": list_mods()}))
        elif path == "/api/maps":
            self._require_auth(lambda: self._json(200, {
                "maps": discover_maps(),
                "current": read_config().get("map") or "/levels/gridmap_v2/info.json",
            }))
        else:
            self._serve_static(path)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/login":
            self._login()
        elif path == "/api/logout":
            token = self._session_token()
            if token:
                SESSIONS.destroy(token)
            self._json(200, {"ok": True, "logout": True})
        elif path == "/api/console":
            self._require_auth(self._console)
        elif path == "/api/restart":
            self._require_auth(self._restart)
        elif path == "/api/config":
            self._require_auth(self._config_post)
        elif path == "/api/mods":
            self._require_auth(self._mods_upload)
        else:
            self._err(404, "not found")

    def do_DELETE(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/mods":
            if not self._authorized():
                self._err(401, "unauthorized")
                return
            qs = urllib.parse.parse_qs(parsed.query)
            name = (qs.get("name") or [""])[0]
            ok, result = delete_mod(name)
            if not ok:
                self._err(400, result)
                return
            self._ok({"name": result})
        else:
            self._err(404, "not found")

    # -- auth ----------------------------------------------------------------

    def _require_auth(self, fn):
        if not self._authorized():
            self._err(401, "unauthorized")
            return
        fn()

    def _login(self):
        body = parse_body(self)
        if body is None:
            self._err(400, "bad request")
            return
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._err(400, "bad request")
            return
        supplied = str(data.get("password", ""))
        expected = required_password()
        if not secrets.compare_digest(supplied.encode(), expected.encode()):
            self._err(401, "invalid password")
            return
        token = SESSIONS.create()
        self._json(200, {"ok": True}, extra={
            "Set-Cookie": f"beammp_session={token}; HttpOnly; Path=/; SameSite=Lax",
        })

    # -- actions -------------------------------------------------------------

    def _console(self):
        body = parse_body(self)
        if body is None:
            self._err(400, "bad request")
            return
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._err(400, "bad request")
            return
        command = str(data.get("command", "")).strip()
        if not command:
            self._err(400, "empty command")
            return
        ok, err = write_console(command)
        if not ok:
            self._err(400, err)
            return
        self._ok({"command": command})

    def _restart(self):
        ok, err = write_console("exit")
        if not ok:
            self._err(400, err)
            return
        self._ok({"message": "restarting"})

    def _config_post(self):
        body = parse_body(self, max_bytes=64 * 1024)
        if body is None:
            self._err(400, "bad request")
            return
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._err(400, "bad request")
            return
        if not isinstance(data, dict) or not data:
            self._err(400, "no fields to update")
            return
        write_config(data)
        self._ok({"restartRequired": True})

    def _mods_upload(self):
        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            self._err(400, "expected multipart/form-data")
            return
        body = parse_body(self)
        if body is None:
            self._err(400, "file too large")
            return
        filename, data = _extract_upload(content_type, body)
        if filename is None:
            self._err(400, "no file part in upload")
            return
        ok, result = save_mod(filename, data)
        if not ok:
            self._err(400, result)
            return
        self._ok({"name": result})

    # -- static --------------------------------------------------------------

    def _serve_static(self, path):
        if path == "/":
            path = "/index.html"
        relative = path.lstrip("/")
        target = (STATIC_DIR / relative).resolve()
        if not str(target).startswith(str(STATIC_DIR.resolve())) or not target.is_file():
            self._err(404, "not found")
            return
        content_type = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
        }.get(target.suffix.lower(), "application/octet-stream")
        self._send(200, target.read_bytes(), content_type,
                   extra={"Cache-Control": "no-cache"})


def _extract_upload(content_type, body):
    boundary = None
    for part in content_type.split(";"):
        part = part.strip()
        if part.startswith("boundary="):
            boundary = part[len("boundary="):].strip('"')
    if not boundary:
        return None, b""
    marker = ("--" + boundary).encode()
    parts = body.split(marker)
    filename = None
    data = b""
    for part in parts:
        if part.startswith(b"\r\n") and b"\r\n\r\n" in part:
            head, _, payload = part[2:].partition(b"\r\n\r\n")
            try:
                headers = email.parser.BytesParser(policy=None).parsebytes(head)
            except Exception:
                continue
            disposition = headers.get("Content-Disposition", "")
            m = re.search(r'filename="([^"]*)"', disposition)
            if m:
                filename = m.group(1)
                data = payload.rstrip(b"\r\n")
                break
    return filename, data


def main():
    parser = argparse.ArgumentParser(description="BeamMP control dashboard")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    required_password()
    httpd = ThreadingHTTPServer(("0.0.0.0", args.port), DashboardHandler)
    httpd.daemon_threads = True
    httpd.serve_forever()


if __name__ == "__main__":
    main()
