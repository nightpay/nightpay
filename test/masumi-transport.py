"""Exercise the gateway's real HTTP helpers against isolated local services.

This verifies routing/authentication/retry behavior, not blockchain payments.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / 'skills/nightpay/scripts/gateway.sh').read_text(encoding='utf-8')
# Load actual helper definitions, avoiding unrelated command startup and custody.
HELPERS = SCRIPT[SCRIPT.index('_ssrf_safe_curl() {'):SCRIPT.index('# Best-effort compatibility layer')]
BASH = os.environ.get('BASH_BIN') or next((str(p) for p in (
    Path('C:/Program Files/Git/bin/bash.exe'), Path('/bin/bash')
) if p.is_file()), shutil.which('bash'))


class MasumiTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BASH:
            raise RuntimeError('Bash is required to test the gateway transport')
        cls.servers = []
        for _ in range(2):
            class Handler(BaseHTTPRequestHandler):
                def handle_request(self):
                    size = int(self.headers.get('Content-Length', '0'))
                    self.server.requests.append((self.command, self.path, dict(self.headers), self.rfile.read(size)))
                    self.send_response(self.server.response_status)
                    self.send_header('Content-Type', 'application/json')
                    self.end_headers()
                    self.wfile.write(b'{"status":"success","data":{}}')
                do_GET = do_POST = handle_request
                def log_message(self, *args):
                    pass
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
            server.requests = []
            server.response_status = 200
            threading.Thread(target=server.serve_forever, daemon=True).start()
            cls.servers.append(server)

    @classmethod
    def tearDownClass(cls):
        for server in cls.servers:
            server.shutdown()
            server.server_close()

    def setUp(self):
        for server in self.servers:
            server.requests.clear()
            server.response_status = 200

    def run_helper(self, command, **env_changes):
        env = dict(os.environ, ALLOW_LOCAL_URLS='1', MASUMI_API_KEY='transport-test-key',
                   MASUMI_PAYMENT_URL=f'http://127.0.0.1:{self.servers[0].server_port}/api/v1',
                   MASUMI_REGISTRY_URL=f'http://127.0.0.1:{self.servers[1].server_port}/api/v1',
                   MASUMI_AUTH_STYLE='token')
        env.update(env_changes)
        return subprocess.run([BASH, '-c', 'set -euo pipefail\n' + HELPERS + '\n' + command],
                              env=env, capture_output=True, text=True, timeout=15)

    def test_purchase_reads_go_to_payment_service(self):
        result = self.run_helper("masumi_get '/purchases/example/status'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.servers[0].requests), 1)
        self.assertEqual(self.servers[1].requests, [])
        method, path, headers, _ = self.servers[0].requests[0]
        self.assertEqual((method, path), ('GET', '/api/v1/purchases/example/status'))
        self.assertEqual(headers.get('token'), 'transport-test-key')
        self.assertNotIn('Authorization', headers)

    def test_payment_post_is_not_retried_after_server_error(self):
        self.servers[0].response_status = 500
        result = self.run_helper("masumi_post '/purchases' '{\"inputHash\":\"example\"}'")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.servers[0].requests), 1)
        self.assertIn('not retried', result.stderr)
        self.assertNotIn('transport-test-key', result.stderr)

    def test_payment_post_is_not_retried_after_auth_error(self):
        self.servers[0].response_status = 401
        result = self.run_helper("masumi_post '/purchases' '{}'")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.servers[0].requests), 1)

    def test_registry_queries_stay_on_registry_service(self):
        result = self.run_helper("masumi_registry_post '/registry-entry-search' '{\"network\":\"Preprod\"}'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.servers[0].requests, [])
        method, path, headers, body = self.servers[1].requests[0]
        self.assertEqual((method, path), ('POST', '/api/v1/registry-entry-search'))
        self.assertEqual(headers.get('token'), 'transport-test-key')
        self.assertEqual(json.loads(body), {'network': 'Preprod'})

    def test_legacy_header_requires_explicit_selection(self):
        result = self.run_helper("masumi_get '/purchases'", MASUMI_AUTH_STYLE='bearer')
        self.assertEqual(result.returncode, 0, result.stderr)
        headers = self.servers[0].requests[0][2]
        self.assertEqual(headers.get('Authorization'), 'Bearer transport-test-key')
        self.assertNotIn('token', headers)

    def test_invalid_auth_settings_fail_before_network(self):
        for changes in ({'MASUMI_AUTH_STYLE': 'guess'}, {'MASUMI_API_KEY': 'test\ninjected: header'}):
            result = self.run_helper("masumi_post '/purchases' '{}'", **changes)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.servers[0].requests, [])


if __name__ == '__main__':
    unittest.main()
