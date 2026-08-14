#!/usr/bin/env python3
"""Standard-library contract tests for the v0.3 provider simulator."""
import importlib.util
import json
from pathlib import Path
from threading import Thread
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import unittest

MODULE = Path(__file__).with_name("server.py")
SPEC = importlib.util.spec_from_file_location("v03_simulator", MODULE)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)

class SimulatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.httpd = SERVER.ThreadingHTTPServer(("127.0.0.1", 0), SERVER.Handler)
        cls.base = f"http://127.0.0.1:{cls.httpd.server_port}"
        cls.thread = Thread(target=cls.httpd.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()

    def request(self, path, body=None, headers=None):
        request = Request(self.base + path, data=body, headers=headers or {}, method="POST" if body is not None else "GET")
        with urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read())

    def state(self, state):
        return self.request("/__admin/state", json.dumps(state).encode(), {"content-type": "application/json"})

    def test_github_paginates_without_recording_authorization(self):
        self.state({"reset": True, "github": {"runs": [{"id": 1, "status": "queued"}, {"id": 2, "status": "queued"}], "jobs": [{"run_id": 1, "status": "queued", "labels": ["self-hosted"]}]}})
        status, body = self.request("/repos/o/r/actions/runs?status=queued&per_page=1&page=1", headers={"Authorization": "Bearer do-not-record"})
        self.assertEqual(status, 200); self.assertEqual(body["workflow_runs"], [{"id": 1, "status": "queued"}])
        status, body = self.request("/__admin/requests")
        self.assertEqual(status, 200); self.assertEqual(body["count"], 1)
        self.assertNotIn("Authorization", json.dumps(body)); self.assertNotIn("do-not-record", json.dumps(body))

    def test_azure_gitlab_and_failure_modes(self):
        self.state({"reset": True, "azure": {"jobs": [{"demands": ["deda"], "assignTime": None, "finishTime": None}]}, "gitlab": {"jobs": [{"status": "pending", "tag_list": ["linux"]}]}})
        _, azure = self.request("/_apis/distributedtask/pools/1/jobrequests?api-version=7.1")
        _, gitlab = self.request("/api/v4/projects/group%2Frepo/jobs?scope[]=pending&scope[]=running&page=1")
        self.assertEqual(len(azure["value"]), 1); self.assertEqual(gitlab[0]["status"], "pending")
        self.state({"mode": {"status": 429, "body": {"error": "limited"}}})
        with self.assertRaises(HTTPError) as error:
            self.request("/api/v4/projects/group%2Frepo/jobs?page=1")
        self.assertEqual(error.exception.code, 429)
        error.exception.close()
        self.state({"mode": {"status": 200, "rawBody": "{"}})
        with self.assertRaises(json.JSONDecodeError):
            self.request("/api/v4/projects/group%2Frepo/jobs?page=1")

if __name__ == "__main__":
    unittest.main()
