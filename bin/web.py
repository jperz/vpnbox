#!/usr/bin/env python3
"""Routehouse Web UI — lightweight stdlib-only HTTP server."""

import json
import os
import re
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

VPN_BIN = "/usr/local/routehouse/bin/vpn.sh"
VPN_DIR = Path("/data/vpns")
RUN_DIR = Path("/data/run")
LOG_DIR = Path("/data/logs")
WEB_DIR = Path("/usr/local/routehouse/web")
PORT = 3100

SERVICES = [
    {"id": "squid",  "name": "Squid",  "desc": "HTTP proxy"},
    {"id": "danted", "name": "SOCKS5", "desc": "Dante SOCKS proxy"},
    {"id": "bird",   "name": "BIRD",   "desc": "Routing daemon"},
    {"id": "sshd",   "name": "SSH",    "desc": "SSH server"},
]
VALID_SERVICE_IDS = {s["id"] for s in SERVICES}
SUPERVISOR_OVERRIDE_DIR = Path("/data/supervisor.d")

MIME = {
    ".html": "text/html; charset=utf-8",
    ".svg":  "image/svg+xml",
    ".css":  "text/css",
    ".js":   "application/javascript",
    ".ico":  "image/x-icon",
}


# ── helpers ──────────────────────────────────────────────────────────────────

def valid_name(name):
    return bool(re.match(r'^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$', name))


def vpn_names():
    try:
        return sorted(p.stem for p in VPN_DIR.glob("*.json")
                      if not p.stem.startswith("sample"))
    except Exception:
        return []


def vpn_config(name):
    try:
        return json.loads((VPN_DIR / f"{name}.json").read_text())
    except Exception:
        return {}


def vpn_pid_file(name):
    """Resolve the pid file the same way vpn.sh does: honor the config's
    pid_file, else default to /data/run/<interface_id>.pid."""
    cfg = vpn_config(name)
    pid = (cfg.get("pid_file") or "").strip()
    return Path(pid) if pid else RUN_DIR / f"{cfg.get('interface_id')}.pid"


def vpn_log_file(name):
    """Resolve the log file the same way vpn.sh does: honor the config's
    log_file, else default to /data/logs/<interface_id>.log."""
    cfg = vpn_config(name)
    log = (cfg.get("log_file") or "").strip()
    return Path(log) if log else LOG_DIR / f"{cfg.get('interface_id')}.log"


def vpn_status(name):
    pid_file = vpn_pid_file(name)
    if not pid_file.exists():
        return "stopped"
    try:
        pid = int(pid_file.read_text().strip())
        os.kill(pid, 0)
        return "running"
    except (ProcessLookupError, PermissionError, ValueError, OSError):
        return "stopped"


def vpn_type(name):
    return vpn_config(name).get("type", "unknown")


def vpn_list():
    return [{"name": n, "status": vpn_status(n), "type": vpn_type(n)}
            for n in vpn_names()]


def vpn_action(name, action):
    try:
        subprocess.Popen([VPN_BIN, action, name],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        return True, None
    except Exception as e:
        return False, str(e)


def read_config(name):
    f = VPN_DIR / f"{name}.json"
    if not f.exists():
        return None, "Not found"
    try:
        return f.read_text(), None
    except Exception as e:
        return None, str(e)


def write_config(name, text):
    try:
        json.loads(text)          # validate JSON
    except json.JSONDecodeError as e:
        return False, f"Invalid JSON: {e}"
    try:
        (VPN_DIR / f"{name}.json").write_text(text)
        return True, None
    except Exception as e:
        return False, str(e)


def delete_vpn(name):
    f = VPN_DIR / f"{name}.json"
    if not f.exists():
        return False, "Not found"
    if vpn_status(name) == "running":
        return False, "VPN is running — stop it first"
    try:
        f.unlink()
        return True, None
    except Exception as e:
        return False, str(e)


def _supervisorctl(*args):
    try:
        r = subprocess.run(["supervisorctl"] + list(args),
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip(), r.returncode == 0
    except Exception:
        return "", False


def service_status(svc_id):
    out, _ = _supervisorctl("status", svc_id)
    if "RUNNING" in out:
        return "running"
    if "STARTING" in out:
        return "starting"
    if "STOPPING" in out:
        return "stopping"
    return "stopped"


def service_enabled(svc_id):
    return not (SUPERVISOR_OVERRIDE_DIR / f"{svc_id}.conf").exists()


def service_list():
    return [
        {**s, "status": service_status(s["id"]), "enabled": service_enabled(s["id"])}
        for s in SERVICES
    ]


def service_action(svc_id, action):
    if action not in ("start", "stop"):
        return False, "Unknown action"
    out, ok = _supervisorctl(action, svc_id)
    return ok, None if ok else out


def _update_supervisor_override(svc_id, enabled):
    SUPERVISOR_OVERRIDE_DIR.mkdir(parents=True, exist_ok=True)
    override = SUPERVISOR_OVERRIDE_DIR / f"{svc_id}.conf"
    if enabled:
        override.unlink(missing_ok=True)
    else:
        override.write_text(f"[program:{svc_id}]\nautostart=false\n")


def service_set_enabled(svc_id, enabled):
    _update_supervisor_override(svc_id, enabled)
    return True, None


def read_logs(name, lines=200):
    f = vpn_log_file(name)
    if not f.exists():
        return "(no log file yet)"
    try:
        content = f.read_text(errors="replace").splitlines()
        return "\n".join(content[-lines:])
    except Exception as e:
        return f"Error: {e}"


# ── request handler ───────────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # silence access log

    # ── response helpers ──────────────────────────────────────────────────────

    def _send(self, status, ctype, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", len(body))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def json(self, data, status=200):
        self._send(status, "application/json", json.dumps(data).encode())

    def text(self, t, status=200):
        self._send(status, "text/plain; charset=utf-8", t.encode())

    def static(self, path: Path):
        suffix = path.suffix.lower()
        ctype = MIME.get(suffix, "application/octet-stream")
        try:
            self._send(200, ctype, path.read_bytes())
        except FileNotFoundError:
            self.json({"error": "not found"}, 404)

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length).decode()

    # ── routing ───────────────────────────────────────────────────────────────

    def do_GET(self):
        p = urlparse(self.path).path
        parts = [x for x in p.split("/") if x]   # drop empty strings

        if p in ("/", "/index.html"):
            self.static(WEB_DIR / "index.html")

        elif len(parts) == 1:                     # /logo.svg etc.
            self.static(WEB_DIR / parts[0])

        elif p == "/api/vpns":
            self.json(vpn_list())

        elif p == "/api/services":
            self.json(service_list())

        elif len(parts) == 4 and parts[0] == "api" and parts[1] == "vpn":
            name, action = parts[2], parts[3]
            if action == "status":
                self.json({"name": name, "status": vpn_status(name)})
            elif action == "config":
                text, err = read_config(name)
                if err:
                    self.json({"error": err}, 404)
                else:
                    self._send(200, "application/json", text.encode())
            elif action == "logs":
                self.text(read_logs(name))
            else:
                self.json({"error": "unknown action"}, 404)
        else:
            self.json({"error": "not found"}, 404)

    def do_POST(self):
        p = urlparse(self.path).path
        parts = [x for x in p.split("/") if x]

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "vpn":
            name, action = parts[2], parts[3]
            if action in ("start", "stop"):
                ok, err = vpn_action(name, action)
                if ok:
                    self.json({"ok": True})
                else:
                    self.json({"ok": False, "error": err}, 500)
            else:
                self.json({"error": "unknown action"}, 404)

        elif len(parts) == 4 and parts[0] == "api" and parts[1] == "service":
            svc_id, action = parts[2], parts[3]
            if svc_id not in VALID_SERVICE_IDS:
                self.json({"error": "unknown service"}, 404)
                return
            if action in ("start", "stop"):
                ok, err = service_action(svc_id, action)
                if ok:
                    self.json({"ok": True})
                else:
                    self.json({"ok": False, "error": err}, 500)
            elif action in ("enable", "disable"):
                enabled = action == "enable"
                ok, err = service_set_enabled(svc_id, enabled)
                if enabled:
                    service_action(svc_id, "start")
                else:
                    service_action(svc_id, "stop")
                self.json({"ok": True})
            else:
                self.json({"error": "unknown action"}, 404)

        else:
            self.json({"error": "not found"}, 404)

    def do_PUT(self):
        p = urlparse(self.path).path
        parts = [x for x in p.split("/") if x]

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "vpn":
            name, action = parts[2], parts[3]
            if action == "config":
                if not valid_name(name):
                    self.json({"ok": False, "error": "Invalid VPN name"}, 400)
                    return
                ok, err = write_config(name, self.read_body())
                if ok:
                    self.json({"ok": True})
                else:
                    self.json({"ok": False, "error": err}, 400)
            else:
                self.json({"error": "unknown action"}, 404)
        else:
            self.json({"error": "not found"}, 404)

    def do_DELETE(self):
        p = urlparse(self.path).path
        parts = [x for x in p.split("/") if x]

        if len(parts) == 3 and parts[0] == "api" and parts[1] == "vpn":
            name = parts[2]
            ok, err = delete_vpn(name)
            if ok:
                self.json({"ok": True})
            else:
                self.json({"ok": False, "error": err}, 400)
        else:
            self.json({"error": "not found"}, 404)


# ── main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Routehouse Web UI  →  http://0.0.0.0:{PORT}", flush=True)
    server.serve_forever()
