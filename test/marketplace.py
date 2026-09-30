"""HTTP integration tests against the real embedded MIP server; no network funds."""
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import subprocess
import unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[1]

class MarketplaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.db_path = str(Path(cls.tmp.name) / 'jobs.db')
        source = (ROOT / 'skills/nightpay/scripts/mip003-server.sh').read_text(encoding='utf-8')
        code = source.split("<<'PYCODE'\n", 1)[1].split('\nPYCODE', 1)[0].split("httpd = ThreadedHTTPServer", 1)[0]
        old_argv = sys.argv
        sys.argv = ['mip-server', '0', cls.db_path, 'marketplace-test-secret', 'operator-test-secret', '24', '1000000', '250', '86400', 'compat', str(ROOT / 'skills/nightpay/ontology')]
        cls.module = {'__file__': str(ROOT / 'skills/nightpay/scripts/mip003-server.sh')}
        try:
            exec(compile(code, 'mip003-server-embedded.py', 'exec'), cls.module)
        finally:
            sys.argv = old_argv
        cls.module['AGENT_IDENTITY_ENFORCE'] = True
        cls.server = cls.module['ThreadedHTTPServer'](('127.0.0.1', 0), cls.module['MIP003Handler'])
        cls.url = f'http://127.0.0.1:{cls.server.server_port}'
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.module['conn'].close()
        # Windows may hold thread-local SQLite handles until the process exits.
        try: cls.tmp.cleanup()
        except PermissionError: pass

    def setUp(self):
        self.agent_id = 'worker.example'
        now = '2026-09-30T12:00:00+00:00'
        with sqlite3.connect(self.db_path) as db:
            db.execute('DELETE FROM agents')
            db.execute('DELETE FROM agent_identities')
            db.execute('DELETE FROM jobs')
            db.execute('DELETE FROM idempotency_keys')
            db.execute('INSERT INTO agents(agent_id,name,metadata,created_at,updated_at) VALUES(?,?,?,?,?)', (self.agent_id, 'Worker', '{}', now, now))
            db.execute('INSERT INTO agent_identities(agent_id,algorithm,public_key_hex,public_key_hash,fingerprint_hash,challenge_id,verified_at,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)', (self.agent_id, 'ed25519', 'aa'*32, 'test-key-hash', 'test-fingerprint', 'fixture', now, now, now))
        self.token = self.module['make_verified_agent_token'](self.agent_id, 'test-fingerprint')
        self.offer = {'offer_id': 'audit', 'title': 'API audit', 'description': 'A written review with actionable findings.', 'price_specks': 25000000, 'delivery_hours': 24, 'revisions': 1, 'conditions': 'Read-only review. Begins after funded escrow. No credentials in briefs.', 'availability': 'available'}

    def request(self, path, body=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['X-Agent-Token'] = token
        req = Request(self.url + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            with urlopen(req, timeout=5) as response: return response.status, json.load(response)
        except HTTPError as exc:
            with exc: return exc.code, json.load(exc)

    def publish(self, **changes):
        profile = {'agent_id': self.agent_id, 'name': 'Audit worker', 'description': 'Independent API review agent', 'capabilities': ['audit'], 'service_offers': [dict(self.offer, **changes)]}
        return self.request('/agent/profile', profile, self.token)

    def order(self, **changes):
        status, profile = self.publish()
        self.assertEqual(status, 200)
        body = {'direct_agent_id': self.agent_id, 'service_offer_id': 'audit', 'service_offer_version': profile['service_offers'][0]['version'], 'accept_service_terms': True, 'amount_specks': 25000000, 'input_data': {'description': 'Review this public API implementation.'}, 'idempotency_key': 'marketplace-order-01'}
        body.update(changes)
        return body

    def test_profile_requires_owner_token_even_when_identity_enforcement_disabled(self):
        self.module['AGENT_IDENTITY_ENFORCE'] = False
        status, _ = self.request('/agent/profile', {'agent_id': self.agent_id})
        self.assertEqual(status, 401)
        status, _ = self.request('/agent/profile', {'agent_id': 'another-worker'}, self.token)
        self.assertEqual(status, 403)
        self.module['AGENT_IDENTITY_ENFORCE'] = True

    def test_offer_discovery_without_showcase(self):
        status, _ = self.publish()
        self.assertEqual(status, 200)
        status, catalog = self.request('/agents?showcase_only=1')
        self.assertEqual(status, 200)
        self.assertEqual(catalog['agents'][0]['service_offers'][0]['title'], 'API audit')

    def test_price_and_boundaries_are_enforced(self):
        for changes in ({'price_specks': True}, {'price_specks': 0}, {'revisions': 21}, {'delivery_hours': 8761}, {'availability': 'unlimited'}):
            self.assertEqual(self.publish(**changes)[0], 400)

    def test_order_requires_consent_and_exact_terms(self):
        for changes, code in (({'accept_service_terms': False}, 400), ({'amount_specks': 1}, 400), ({'service_offer_version': 'stale'}, 409), ({'visibility': 'public'}, 400)):
            self.assertEqual(self.request('/start_job', self.order(**changes))[0], code)

    def test_order_is_private_snapshotted_unfunded_and_replay_safe(self):
        body = self.order()
        status, order = self.request('/start_job', body)
        self.assertEqual(status, 200)
        with sqlite3.connect(self.db_path) as db:
            payload, visibility = db.execute('SELECT input_data,visibility FROM jobs WHERE job_id=?', (order['job_id'],)).fetchone()
            terms = json.loads(payload)['service_order']
        self.assertEqual(terms['offer']['price_specks'], 25000000)
        self.assertEqual(terms['payment_status'], 'unfunded')
        self.assertNotEqual(visibility, 'public')
        self.assertEqual(self.request('/jobs')[1]['jobs'], [])
        self.publish(price_specks=30000000)
        status, replay = self.request('/start_job', body)
        self.assertEqual(status, 200)
        self.assertEqual(replay['job_id'], order['job_id'])
        self.assertTrue(replay['idempotent_replay'])
        self.assertEqual(self.request('/start_job', dict(body, idempotency_key='marketplace-order-02'))[0], 409)

    def test_paused_offer_cannot_be_ordered(self):
        body = self.order()
        self.publish(availability='paused')
        self.assertEqual(self.request('/start_job', body)[0], 409)

    def test_revoked_provider_is_not_hireable(self):
        body = self.order()
        with sqlite3.connect(self.db_path) as db:
            db.execute("UPDATE agent_identities SET revoked_at='2026-09-30T13:00:00+00:00' WHERE agent_id=?", (self.agent_id,))
        self.assertEqual(self.request('/start_job', body)[0], 409)

    def test_cli_register_publish_and_reject_key_takeover(self):
        # This uses real Ed25519 challenge signing, rather than fixture tokens.
        with tempfile.TemporaryDirectory() as state_dir:
            env = dict(os.environ, NIGHTPAY_API_URL=self.url, HOME=state_dir, USERPROFILE=state_dir)
            register = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'agent-register', 'cli-worker'], env=env, capture_output=True, text=True)
            self.assertEqual(register.returncode, 0, register.stderr)
            profile = {'agent_id': 'cli-worker', 'name': 'CLI worker', 'description': 'Verified through the real npm CLI', 'capabilities': ['audit'], 'service_offers': [self.offer]}
            profile_path = Path(state_dir) / 'profile.json'
            profile_path.write_text(json.dumps(profile))
            published = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'publish-profile', str(profile_path)], env=env, capture_output=True, text=True)
            self.assertEqual(published.returncode, 0, published.stderr)
            self.assertEqual(self.request('/agents/cli-worker')[1]['service_offers'][0]['title'], 'API audit')
            with tempfile.TemporaryDirectory() as attacker:
                attack_env = dict(env, HOME=attacker, USERPROFILE=attacker)
                takeover = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'agent-register', 'cli-worker'], env=attack_env, capture_output=True, text=True)
                self.assertNotEqual(takeover.returncode, 0)
                self.assertIn('409', takeover.stderr)
            with sqlite3.connect(self.db_path) as db:
                db.execute("UPDATE agent_identities SET revoked_at='2026-09-30T13:00:00+00:00' WHERE agent_id='cli-worker'")
            revoked = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'agent-register', 'cli-worker'], env=env, capture_output=True, text=True)
            self.assertNotEqual(revoked.returncode, 0)
            self.assertIn('403', revoked.stderr)

if __name__ == '__main__':
    unittest.main()
