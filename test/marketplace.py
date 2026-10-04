"""HTTP integration tests against the real embedded MIP server; no network funds."""
import json
import hashlib
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import subprocess
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
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
            db.execute('INSERT INTO agent_identities(agent_id,algorithm,public_key_hex,public_key_hash,fingerprint_hash,challenge_id,verified_at,masumi_agent_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)', (self.agent_id, 'ed25519', 'aa'*32, 'test-key-hash', 'test-fingerprint', 'fixture', now, 'masumi-worker-identifier-123456789', now, now))
        self.token = self.module['make_verified_agent_token'](self.agent_id, 'test-fingerprint')
        self.offer = {'offer_id': 'audit', 'title': 'API audit', 'description': 'A written review with actionable findings.', 'price_specks': 25000000, 'delivery_hours': 24, 'revisions': 1, 'conditions': 'Read-only review. Begins after funded escrow. No credentials in briefs.', 'availability': 'available'}

    def request(self, path, body=None, token=None, bearer=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['X-Agent-Token'] = token
        if bearer: headers['Authorization'] = f'Bearer {bearer}'
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
        body = {'direct_agent_id': self.agent_id, 'service_offer_id': 'audit', 'service_offer_version': profile['service_offers'][0]['version'], 'accept_service_terms': True, 'amount_specks': 25000000, 'agentIdentifier': 'masumi-worker-identifier-123456789', 'sellerVkey': 'ab' * 32, 'network': 'Preprod', 'Amounts': [{'unit': 'lovelace', 'amount': '10000000'}], 'input_data': {'description': 'Review this public API implementation.'}, 'idempotency_key': 'marketplace-order-01'}
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
        status, availability = self.request('/availability')
        self.assertEqual(status, 200)
        self.assertFalse(availability['service_orders']['paid_checkout_available'])
        status, _ = self.publish()
        self.assertEqual(status, 200)
        status, catalog = self.request('/agents?showcase_only=1')
        self.assertEqual(status, 200)
        self.assertEqual(catalog['agents'][0]['service_offers'][0]['title'], 'API audit')

    def test_price_and_boundaries_are_enforced(self):
        for changes in ({'price_specks': True}, {'price_specks': 0}, {'price_specks': 999}, {'price_specks': 500000001}, {'revisions': 21}, {'delivery_hours': 8761}, {'availability': 'unlimited'}):
            self.assertEqual(self.publish(**changes)[0], 400)

    def test_order_requires_consent_and_exact_terms(self):
        for changes, code in (({'accept_service_terms': False}, 400), ({'amount_specks': 1}, 400), ({'service_offer_version': 'stale'}, 409), ({'visibility': 'public'}, 400)):
            self.assertEqual(self.request('/start_job', self.order(**changes))[0], code)

    def test_order_is_private_snapshotted_unfunded_and_replay_safe(self):
        body = self.order()
        status, order = self.request('/start_job', body)
        self.assertEqual(status, 200)
        self.assertEqual(order['status'], 'awaiting_payment')
        self.assertEqual(order['internal_status'], 'awaiting_payment')
        with sqlite3.connect(self.db_path) as db:
            payload, visibility = db.execute('SELECT input_data,visibility FROM jobs WHERE job_id=?', (order['job_id'],)).fetchone()
            terms = self.module['decode_service_input'](order['job_id'], json.loads(payload))['service_order']
        self.assertEqual(terms['offer']['price_specks'], 25000000)
        self.assertEqual(terms['payment_status'], 'unfunded')
        self.assertNotEqual(visibility, 'public')
        self.assertEqual(self.request('/jobs')[1]['jobs'], [])
        self.publish(price_specks=30000000)
        status, replay = self.request('/start_job', body)
        self.assertEqual(status, 200)
        self.assertEqual(replay['job_id'], order['job_id'])
        self.assertEqual(replay['status'], 'awaiting_payment')
        self.assertTrue(replay['idempotent_replay'])
        self.assertEqual(self.request('/start_job', dict(body, idempotency_key='marketplace-order-02'))[0], 409)

    def test_unfunded_order_rejects_delivery_and_completion(self):
        body = self.order(input_data={'description': 'Review this API.', 'service_order': {'payment_status': 'funded'}})
        code, order = self.request('/start_job', body)
        self.assertEqual(code, 200)
        job_id, job_token = order['job_id'], order['job_token']
        code, status = self.request(f'/status/{job_id}', bearer=job_token)
        self.assertEqual(code, 200)
        self.assertEqual(status['status'], 'awaiting_payment')
        self.assertEqual(status['input_data']['service_order']['payment_status'], 'unfunded')
        worker_status, worker_view = self.request(f'/status/{job_id}', token=self.token)
        self.assertEqual(worker_status, 200)
        self.assertEqual(worker_view['status'], 'awaiting_payment')
        self.assertNotIn('input_data', worker_view)
        worker_status, worker_view = self.request(f'/status/{job_id}', token=self.token)
        self.assertEqual(worker_status, 200)
        self.assertEqual(worker_view['status'], 'awaiting_payment')
        self.assertNotIn('input_data', worker_view)
        for path, payload, bearer in (
            ('provide_input', {'agent_id': self.agent_id, 'input_data': {'work': 'Review delivered'}}, job_token),
            ('provide_result', {'agent_id': self.agent_id, 'work_output': 'Complete review with findings.'}, job_token),
            ('complete_job', {'onChain': True, 'receiptHash': 'aa' * 32}, 'operator-test-secret'),
        ):
            code, result = self.request(f'/{path}/{job_id}', payload, self.token, bearer=bearer)
            self.assertEqual(code, 409, result)
        with sqlite3.connect(self.db_path) as db:
            self.assertEqual(db.execute('SELECT status FROM jobs WHERE job_id=?', (job_id,)).fetchone()[0], 'awaiting_payment')
            self.assertEqual(db.execute('SELECT status FROM job_status_events WHERE job_id=?', (job_id,)).fetchone()[0], 'awaiting_payment')

    def test_private_brief_is_encrypted_and_bound_to_authorized_job(self):
        brief = 'Private service brief: unique customer requirements 7d8146.'
        code, order = self.request('/start_job', self.order(input_data={'description': brief}))
        self.assertEqual(code, 200)
        job_id = order['job_id']
        self.assertEqual(self.request(f'/status/{job_id}')[0], 403)
        with sqlite3.connect(self.db_path) as db:
            stored = db.execute('SELECT input_data FROM jobs WHERE job_id=?', (job_id,)).fetchone()[0]
            self.assertNotIn(brief, stored)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM jobs_fts WHERE input_data LIKE ?', ('%' + brief + '%',)).fetchone()[0], 0)
        for path in Path(self.tmp.name).glob('jobs.db*'):
            self.assertNotIn(brief.encode(), path.read_bytes())
        code, status = self.request(f'/status/{job_id}', bearer=order['job_token'])
        self.assertEqual(code, 200)
        self.assertEqual(status['input_data']['description'], brief)
        envelope = json.loads(stored)
        with self.assertRaises(Exception):
            self.module['decode_service_input']('another-job', envelope)
        encrypted = envelope['encrypted_service_input']
        encrypted['ciphertext'] = encrypted['ciphertext'][:-4] + 'AAAA'
        with sqlite3.connect(self.db_path) as db:
            db.execute('UPDATE jobs SET input_data=? WHERE job_id=?', (json.dumps(envelope), job_id))
        code, status = self.request(f'/status/{job_id}', bearer=order['job_token'])
        self.assertEqual(code, 503)
        self.assertNotIn(brief, json.dumps(status))

    def test_strict_order_and_replay_keep_payment_status(self):
        body = self.order(agentIdentifier='masumi-worker-identifier-123456789', identifier_from_purchaser='aabbccddeeff001122334455')
        self.module['MIP003_MODE'] = 'strict'
        try:
            code, order = self.request('/start_job', body)
            self.assertEqual(code, 200, order)
            for result in (order, self.request('/start_job', body)[1]):
                self.assertEqual(result['status'], 'awaiting_payment')
                self.assertEqual(result['internal_status'], 'awaiting_payment')
                self.assertEqual(result['legacy']['status'], 'awaiting_payment')
            self.assertEqual(order['agentIdentifier'], 'masumi-worker-identifier-123456789')
            self.assertEqual(order['sellerVkey'], 'ab' * 32)
            self.assertEqual(order['inputHash'], order['input_data_hash'])
            self.assertTrue(order['payByTime'].isdigit())
            self.assertNotIn('T', order['payByTime'])
        finally:
            self.module['MIP003_MODE'] = 'compat'

    def test_masumi_funds_locked_is_verified_before_order_unlock(self):
        body = self.order()
        code, order = self.request('/start_job', body)
        self.assertEqual(code, 200)
        class MasumiHandler(BaseHTTPRequestHandler):
            requested_funds = [{'unit': 'lovelace', 'amount': '9000000'}]
            def do_POST(inner_self):
                self.assertEqual(inner_self.path, '/api/v1/payment/resolve-blockchain-identifier')
                self.assertEqual(inner_self.headers.get('token'), 'mock-masumi-key')
                request_data = json.loads(inner_self.rfile.read(int(inner_self.headers['Content-Length'])))
                self.assertEqual(request_data, {'blockchainIdentifier': order['job_id'], 'network': 'Preprod', 'includeHistory': 'false'})
                payload = json.dumps({'status': 'success', 'data': {'id': 'mock-inbound-payment-01', 'NextAction': {'requestedAction': 'FundsLocked'}, 'RequestedFunds': MasumiHandler.requested_funds}}).encode()
                inner_self.send_response(200)
                inner_self.send_header('Content-Type', 'application/json')
                inner_self.send_header('Content-Length', str(len(payload)))
                inner_self.end_headers()
                inner_self.wfile.write(payload)
            def log_message(inner_self, *_args): pass
        masumi = HTTPServer(('127.0.0.1', 0), MasumiHandler)
        thread = threading.Thread(target=masumi.serve_forever, daemon=True)
        thread.start()
        old_config = (self.module['MASUMI_API_KEY'], self.module['MASUMI_PAYMENT_URL'], self.module['MASUMI_NETWORK'])
        try:
            self.module['MASUMI_API_KEY'] = 'mock-masumi-key'
            self.module['MASUMI_PAYMENT_URL'] = f'http://127.0.0.1:{masumi.server_port}/api/v1'
            self.module['MASUMI_NETWORK'] = 'Preprod'
            code, status = self.request(f"/status/{order['job_id']}", bearer=order['job_token'])
            self.assertEqual(code, 200)
            self.assertEqual(status['status'], 'awaiting_payment')
            MasumiHandler.requested_funds = [{'unit': 'lovelace', 'amount': '10000000'}]
            code, status = self.request(f"/status/{order['job_id']}", bearer=order['job_token'])
            self.assertEqual(code, 200)
            self.assertEqual(status['status'], 'running')
            self.assertEqual(status['input_data']['service_order']['payment_status'], 'funded')
            self.assertEqual(status['input_data']['service_order']['masumi_payment_id'], 'mock-inbound-payment-01')
            with sqlite3.connect(self.db_path) as db:
                self.assertEqual(db.execute('SELECT status FROM jobs WHERE job_id=?', (order['job_id'],)).fetchone()[0], 'running')
        finally:
            self.module['MASUMI_API_KEY'], self.module['MASUMI_PAYMENT_URL'], self.module['MASUMI_NETWORK'] = old_config
            masumi.shutdown()
            masumi.server_close()

    def test_cli_checkout_connects_registry_order_and_purchase_contract(self):
        self.publish()
        class MasumiHandler(BaseHTTPRequestHandler):
            purchase_body = None
            result_body = None
            service_api = self.url
            def do_GET(inner_self):
                self.assertTrue(inner_self.path.startswith('/api/v1/payment-information?agentIdentifier='))
                payload = json.dumps({'status': 'success', 'data': {
                    'status': 'Online', 'agentIdentifier': 'masumi-worker-identifier-123456789',
                    'sellerWallet': {'address': 'addr_test1worker', 'vkey': 'ab' * 32},
                    'apiBaseUrl': MasumiHandler.service_api,
                    'paymentType': 'Web3CardanoV1',
                    'AgentPricing': {'pricingType': 'Fixed', 'FixedPricing': {'Amounts': [{'unit': 'lovelace', 'amount': '10000000'}]}},
                }}).encode()
                inner_self.send_response(200); inner_self.send_header('Content-Type', 'application/json')
                inner_self.send_header('Content-Length', str(len(payload))); inner_self.end_headers(); inner_self.wfile.write(payload)
            def do_POST(inner_self):
                data = json.loads(inner_self.rfile.read(int(inner_self.headers['Content-Length'])))
                if inner_self.path == '/api/v1/purchase':
                    MasumiHandler.purchase_body = data
                    payload = json.dumps({'status': 'success', 'data': {'id': 'mock-purchase-01', 'NextAction': {'requestedAction': 'FundsLockingRequested'}}}).encode()
                elif inner_self.path == '/api/v1/payment/resolve-blockchain-identifier':
                    self.assertEqual(data['network'], 'Preprod')
                    payload = json.dumps({'status': 'success', 'data': {'NextAction': {'requestedAction': 'FundsLocked'}, 'RequestedFunds': [{'unit': 'lovelace', 'amount': '10000000'}]}}).encode()
                elif inner_self.path == '/api/v1/payment/submit-result':
                    MasumiHandler.result_body = data
                    payload = json.dumps({'status': 'success', 'data': {'id': 'mock-payment-01', 'NextAction': {'requestedAction': 'ResultSubmitted'}}}).encode()
                else:
                    inner_self.send_error(404); return
                inner_self.send_response(200); inner_self.send_header('Content-Type', 'application/json')
                inner_self.send_header('Content-Length', str(len(payload))); inner_self.end_headers(); inner_self.wfile.write(payload)
            def log_message(inner_self, *_args): pass
        masumi = HTTPServer(('127.0.0.1', 0), MasumiHandler)
        thread = threading.Thread(target=masumi.serve_forever, daemon=True); thread.start()
        base = f'http://127.0.0.1:{masumi.server_port}/api/v1'
        old_config = (self.module['MASUMI_API_KEY'], self.module['MASUMI_PAYMENT_URL'], self.module['MASUMI_NETWORK'])
        try:
            with tempfile.TemporaryDirectory() as tmp:
                brief = Path(tmp) / 'brief.txt'; brief.write_text('Review this public API implementation.', encoding='utf-8')
                env = dict(os.environ, NIGHTPAY_API_URL=self.url, MASUMI_API_KEY='mock-masumi-key',
                           MASUMI_PAYMENT_URL=base, MASUMI_REGISTRY_URL=base, MASUMI_NETWORK='Preprod',
                           HOME=tmp, USERPROFILE=tmp)
                unavailable = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'hire-service', self.agent_id, 'audit', str(brief)],
                    input='PAY PREPROD\n', env=env, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(unavailable.returncode, 0)
                self.assertIn('No order or payment was submitted', unavailable.stderr)
                self.assertIsNone(MasumiHandler.purchase_body)
                self.module['MASUMI_API_KEY'] = 'mock-masumi-key'
                self.module['MASUMI_PAYMENT_URL'] = base
                self.module['MASUMI_NETWORK'] = 'Preprod'
                preview = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'hire-service', self.agent_id, 'audit', str(brief), '--dry-run'],
                                         env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(preview.returncode, 0, preview.stderr)
                self.assertIn('10000000', preview.stdout)
                self.assertIn('PAY PREPROD', preview.stdout)
                self.assertIsNone(MasumiHandler.purchase_body)
                rejected = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'hire-service', self.agent_id, 'audit', str(brief), '--confirm', 'no'],
                                          env=env, capture_output=True, text=True, timeout=30)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('no order or purchase was submitted', rejected.stderr)
                self.assertNotIn('Assertion failed', rejected.stderr)
                self.assertIsNone(MasumiHandler.purchase_body)
                result = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'hire-service', self.agent_id, 'audit', str(brief), '--confirm', 'PAY PREPROD'],
                                         env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                output = json.loads(result.stdout[result.stdout.rfind('\n{') + 1:])
                self.assertEqual(output['purchase_id'], 'mock-purchase-01')
                self.assertEqual(output['network'], 'Preprod')
                self.assertEqual(output['nightpay_status'], 'running')
                self.assertNotIn('job_token', output)
                worker_status, worker_job = self.request(f"/status/{output['job_id']}", token=self.token)
                self.assertEqual(worker_status, 200)
                self.assertEqual(worker_job['input_data']['description'], 'Review this public API implementation.')
                delivered, result = self.request(f"/provide_result/{output['job_id']}",
                    {'agent_id': self.agent_id, 'work_output': 'Completed API audit with prioritized actionable findings.'}, token=self.token)
                self.assertEqual(delivered, 200, result)
                self.assertEqual(result['masumi_result_submission'], 'submitted')
                with sqlite3.connect(self.db_path) as db:
                    saved_result = db.execute('SELECT result FROM jobs WHERE job_id=?', (output['job_id'],)).fetchone()[0]
                    self.assertNotIn('Completed API audit with prioritized actionable findings.', saved_result)
                status_result = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'service-status', output['job_id']],
                    env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(status_result.returncode, 0, status_result.stderr)
                buyer_view = json.loads(status_result.stdout)
                self.assertEqual(buyer_view['result']['work_output'], 'Completed API audit with prioritized actionable findings.')
                self.assertEqual(buyer_view['result']['masumi_result_submission']['status'], 'submitted')
                sent = MasumiHandler.purchase_body
                self.assertEqual(sent['network'], 'Preprod')
                self.assertEqual(sent['sellerVkey'], 'ab' * 32)
                self.assertEqual(sent['Amounts'], [{'unit': 'lovelace', 'amount': '10000000'}])
                self.assertEqual(sent['inputHash'], hashlib.sha256(b'{"description":"Review this public API implementation."}').hexdigest())
                self.assertEqual(MasumiHandler.result_body, {
                    'blockchainIdentifier': output['job_id'], 'network': 'Preprod',
                    'submitResultHash': hashlib.sha256(b'Completed API audit with prioritized actionable findings.').hexdigest(),
                })
        finally:
            self.module['MASUMI_API_KEY'], self.module['MASUMI_PAYMENT_URL'], self.module['MASUMI_NETWORK'] = old_config
            masumi.shutdown(); masumi.server_close()

    def test_non_idempotent_order_and_reserved_snapshot(self):
        body = self.order()
        del body['idempotency_key']
        code, order = self.request('/start_job', body)
        self.assertEqual(code, 200)
        self.assertEqual(order['status'], 'awaiting_payment')
        plain_body = {'amount_specks': 25000000, 'input_data': {'description': 'Ordinary job', 'service_order': {'payment_status': 'funded'}}}
        code, ordinary = self.request('/start_job', plain_body)
        self.assertEqual(code, 200)
        self.assertEqual(ordinary['internal_status'], 'running')
        with sqlite3.connect(self.db_path) as db:
            payload = db.execute('SELECT input_data FROM jobs WHERE job_id=?', (ordinary['job_id'],)).fetchone()[0]
        self.assertNotIn('service_order', json.loads(payload))

    def test_merge_keeps_standing_offers_for_other_agents(self):
        self.publish()
        second = dict(self.offer, offer_id='docs', title='Write docs', description='A written document with the requested sections.', conditions='Public sources only. One revision after delivery.')
        status, profile = self.request('/agent/profile', {
            'agent_id': self.agent_id, 'name': 'Audit worker', 'description': 'Independent API review agent',
            'capabilities': ['audit', 'docs'], 'service_offers': [second], 'service_offer_mode': 'merge',
        }, self.token)
        self.assertEqual(status, 200, profile)
        self.assertEqual([offer['offer_id'] for offer in profile['service_offers']], ['audit', 'docs'])
        status, catalog = self.request('/agents?showcase_only=1')
        self.assertEqual(status, 200)
        listed = catalog['agents'][0]['service_offers']
        self.assertEqual([offer['offer_id'] for offer in listed], ['audit', 'docs'])
        self.assertTrue(all(offer['availability'] == 'available' for offer in listed))

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
            register = subprocess.run(['node', str(ROOT / 'bin/cli.js'), 'agent-register', 'cli-worker', '--masumi-agent-id', 'cli-masumi-agent-identifier-123456789'], env=env, capture_output=True, text=True)
            self.assertEqual(register.returncode, 0, register.stderr)
            self.assertEqual(self.request('/agents/cli-worker')[1]['identity']['masumi_agent_id'], 'cli-masumi-agent-identifier-123456789')
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

    def test_public_job_status_is_readable(self):
        code, job = self.request('/start_job', {'amount_specks': 500000, 'visibility': 'public', 'input_data': {'description': 'Public status check.', 'amount_specks': 500000}})
        self.assertEqual(code, 200, job)
        code, status = self.request(f"/status/{job['job_id']}")
        self.assertEqual(code, 200, status)
        self.assertEqual(status['internal_status'], 'running')

if __name__ == '__main__':
    unittest.main()
