#!/usr/bin/env python3
"""Small, stateful CI provider simulator for DEDA v0.3 qualification.

It intentionally implements only the GET endpoints consumed by DEDA.  Scenario
scripts change state through /__admin; Authorization and PRIVATE-TOKEN headers
are never persisted.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse
from datetime import datetime, timezone
import json
import os
import threading
import time

LOCK = threading.Lock()
STATE = {
    "github": {"runs": [{"id": 1}], "jobs": []},
    "azure": {"pools": [{"id": 1, "name": "deda"}], "jobs": []},
    "gitlab": {"jobs": []},
    "mode": {"status": 200, "body": None, "rawBody": None, "delaySeconds": 0},
    "requests": [],
}

def utcnow():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

def compact_state():
    """Give operators a reviewable state without any request headers."""
    return STATE

def page(items, query):
    size = int(query.get("per_page", ["100"])[0])
    number = int(query.get("page", ["1"])[0])
    first = (number - 1) * size
    return items[first:first + size], number * size < len(items)

class Handler(BaseHTTPRequestHandler):
    server_version = "deda-ci-simulator/1"

    def log_message(self, fmt, *args):
        return

    def json(self, status, body, headers=None):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        self.wfile.write(payload)

    def record(self, path):
        with LOCK:
            STATE["requests"].append({"at": utcnow(), "endpoint": path, "mode": dict(STATE["mode"])})
            del STATE["requests"][:-500]
            return dict(STATE["mode"])

    def provider_error(self, mode):
        if mode["delaySeconds"]:
            time.sleep(min(float(mode["delaySeconds"]), 30))
        if mode.get("rawBody") is not None:
            payload = mode["rawBody"].encode()
            self.send_response(mode["status"])
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return True
        if mode.get("body") is not None:
            self.json(mode["status"], mode["body"])
            return True
        if mode["status"] != 200:
            self.json(mode["status"], {"error": "simulated provider failure"})
            return True
        return False

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz": return self.json(200, {"status": "ok"})
        if parsed.path == "/__admin/state":
            with LOCK: return self.json(200, compact_state())
        if parsed.path == "/__admin/requests":
            with LOCK: return self.json(200, {"requests": STATE["requests"], "count": len(STATE["requests"])})
        mode = self.record(parsed.path)
        if self.provider_error(mode): return
        query = parse_qs(parsed.query)
        with LOCK:
            if parsed.path.endswith("/actions/runs"):
                status = query.get("status", [""])[0]
                runs = [run for run in STATE["github"]["runs"] if run.get("status") == status]
                result, more = page(runs, query)
                headers = {"Link": '<next>; rel="next"'} if more else {}
                return self.json(200, {"workflow_runs": result}, headers)
            if "/actions/runs/" in parsed.path and parsed.path.endswith("/jobs"):
                run_id = int(parsed.path.split("/actions/runs/")[1].split("/")[0])
                jobs = [job for job in STATE["github"]["jobs"] if job.get("run_id", 1) == run_id]
                result, more = page(jobs, query)
                headers = {"Link": '<next>; rel="next"'} if more else {}
                return self.json(200, {"jobs": result}, headers)
            if parsed.path.endswith("/_apis/distributedtask/pools"):
                name = query.get("poolName", [""])[0]
                return self.json(200, {"value": [pool for pool in STATE["azure"]["pools"] if pool["name"] == name]})
            if "/_apis/distributedtask/pools/" in parsed.path and parsed.path.endswith("/jobrequests"):
                return self.json(200, {"value": STATE["azure"]["jobs"]})
            if "/api/v4/projects/" in parsed.path and parsed.path.endswith("/jobs"):
                result, more = page(STATE["gitlab"]["jobs"], query)
                return self.json(200, result, {"X-Next-Page": str(int(query.get("page", ["1"])[0]) + 1) if more else ""})
        return self.json(404, {"error": "unsupported simulator endpoint", "path": unquote(parsed.path)})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/__admin/state": return self.json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            change = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self.json(400, {"error": "invalid JSON"})
        with LOCK:
            if change.get("reset"):
                STATE["github"] = {"runs": [{"id": 1}], "jobs": []}
                STATE["azure"] = {"pools": [{"id": 1, "name": "deda"}], "jobs": []}
                STATE["gitlab"] = {"jobs": []}
                STATE["requests"] = []
                STATE["mode"] = {"status": 200, "body": None, "rawBody": None, "delaySeconds": 0}
            for provider in ("github", "azure", "gitlab"):
                if provider in change:
                    STATE[provider].update(change[provider])
            if "mode" in change:
                STATE["mode"].update(change["mode"])
        return self.json(200, {"status": "updated"})

if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.getenv("PORT", "8081"))), Handler).serve_forever()
