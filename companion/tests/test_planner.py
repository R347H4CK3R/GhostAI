"""Planner contract tests: fake model transport, real memory and validation."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from companion.core import Memory, PlanError, load_plan, validate

SPEC = importlib.util.find_spec('companion.planner')
if SPEC:
    from companion.planner import generate_plan, local_transport

PLAN = {'version': 1, 'steps': [{'tool': 'read_file', 'path': 'input.txt'},
        {'tool': 'write_draft', 'path': 'draft.txt', 'content': 'Review this full draft.'}],
        'write_paths': ['draft.txt'], 'budgets': {}}


class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC, 'local model planner is not implemented')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.memory = Memory(self.root / 'memory.sqlite')
        self.addCleanup(self.memory.close)
        self.requests = []

    def fake(self, payload):
        self.requests.append(json.loads(payload))
        return json.dumps({'response': json.dumps(PLAN), 'done': True}).encode()

    def generate(self, **kwargs):
        return generate_plan('Inspect input.txt and propose a draft.', 'demo', 'qwen2.5-coder:7b',
                             self.memory, transport=kwargs.pop('transport', self.fake), **kwargs)

    def test_returns_full_validated_plan_and_risk_summary_without_execution(self):
        with patch('companion.core.Runner.run', side_effect=AssertionError('must not execute')):
            result = self.generate()
        self.assertEqual(result['status'], 'generated')
        self.assertFalse(result['executed'])
        self.assertEqual(result['plan'], PLAN)
        validate(load_plan(json.dumps(result['plan'])))
        self.assertEqual(result['summary']['read_paths'], ['input.txt'])
        self.assertEqual(result['summary']['write_paths'], ['draft.txt'])
        self.assertTrue(result['summary']['requires_write_approval'])
        self.assertEqual(result['summary']['risk'], 'new_local_drafts')
        self.assertEqual(self.memory.tasks(), [])
        self.assertFalse((self.root / 'draft.txt').exists())

    def test_memory_is_project_scoped_and_bounded(self):
        self.memory.add('other', 'OTHER_PROJECT_PRIVATE', 'other-source')
        for index in range(8):
            self.memory.add('demo', 'é' * 10000, 'local-' + str(index))
        self.generate()
        prompt = self.requests[0]['prompt']
        self.assertNotIn('OTHER_PROJECT_PRIVATE', prompt)
        self.assertNotIn('other-source', prompt)
        self.assertLessEqual(len(prompt.encode()), 24576)
        self.assertTrue(self.requests[0]['stream'] is False)
        self.assertEqual(self.requests[0]['format'], 'json')
        self.assertIn('local-', prompt)

    def test_oversized_goal_rejected_before_transport(self):
        with self.assertRaises(PlanError):
            generate_plan('é' * 9000, 'demo', 'local', self.memory, transport=self.fake)
        self.assertEqual(self.requests, [])

    def test_external_endpoint_rejected_before_transport(self):
        for endpoint in ['https://example.com', 'http://localhost:11434',
                         'http://127.0.0.1:11434@evil.test', 'http://127.0.0.1:11434/']:
            with self.subTest(endpoint=endpoint), self.assertRaises(PlanError):
                self.generate(endpoint=endpoint)
        self.assertEqual(self.requests, [])

    def test_cloud_and_remote_model_names_rejected(self):
        for model in ['gpt-oss:120b-cloud', 'https://remote/model', 'user/model', '', 'x\nheader']:
            with self.subTest(model=model), self.assertRaises(PlanError):
                generate_plan('Inspect', 'demo', model, self.memory, transport=self.fake)
        self.assertEqual(self.requests, [])

    def test_malformed_or_unsupported_output_rejected(self):
        invalid_plans = ['```json\n{}\n```', '{', '{"version":1,"version":1}',
                         json.dumps(dict(PLAN, steps=[{'tool': 'shell', 'path': 'ls'}]))]
        raw_responses = [json.dumps({'response': plan, 'done': True}).encode() for plan in invalid_plans]
        raw_responses += [b'not json', b'{"response":"{}","done":false}',
                          b'{"response":2,"done":true}', b'x' * 1048577]
        for response in raw_responses:
            with self.subTest(response=response[:60]), self.assertRaises(PlanError):
                self.generate(transport=lambda payload: response)

    def test_read_only_summary(self):
        plan = dict(PLAN, steps=[{'tool': 'list_files', 'path': '.'}], write_paths=[])
        result = self.generate(transport=lambda payload: json.dumps({'response': json.dumps(plan), 'done': True}).encode())
        self.assertEqual(result['summary']['risk'], 'local_read_only')
        self.assertFalse(result['summary']['requires_write_approval'])

    def test_no_model_failure_is_hidden(self):
        def failed(payload):
            raise TimeoutError('timed out')
        with self.assertRaises(PlanError):
            self.generate(transport=failed)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(SPEC, 'local model planner is not implemented')

    def test_redirect_rejected_and_connection_closed(self):
        class Response:
            status = 307
        class Connection:
            closed = False
            def __init__(self, host, port, timeout):
                self_test.assertEqual((host, port), ('127.0.0.1', 11434))
                self_test.assertLessEqual(timeout, 30)
            def connect(self):
                self.sock = None
            def request(self, method, path, body, headers):
                self_test.assertEqual((method, path), ('POST', '/api/generate'))
            def getresponse(self):
                return Response()
            def close(self):
                Connection.closed = True
        self_test = self
        with patch('companion.planner.http.client.HTTPConnection', Connection):
            with self.assertRaises(PlanError):
                local_transport(b'{}')
        self.assertTrue(Connection.closed)

    def test_response_read_is_bounded_and_connection_errors_fail_closed(self):
        outer = self
        class Response:
            status = 200
            def read(self, limit):
                outer.assertEqual(limit, 1048577)
                return b'x' * limit
        class Connection:
            def __init__(self, *args, **kwargs):
                pass
            def connect(self):
                self.sock = None
            def request(self, *args, **kwargs):
                pass
            def getresponse(self):
                return Response()
            def close(self):
                pass
        with patch('companion.planner.http.client.HTTPConnection', Connection):
            with self.assertRaises(PlanError):
                local_transport(b'{}')
        with patch('companion.planner.http.client.HTTPConnection.connect', side_effect=ConnectionRefusedError):
            with self.assertRaises(PlanError):
                local_transport(b'{}')

    def test_deadline_shuts_down_socket(self):
        events = []
        class Socket:
            def shutdown(self, mode):
                events.append('shutdown')
            def close(self):
                events.append('socket_closed')
        class Connection:
            def __init__(self, *args, **kwargs):
                pass
            def connect(self):
                self.sock = Socket()
            def request(self, *args, **kwargs):
                raise OSError('closed by deadline')
            def close(self):
                events.append('connection_closed')
        class Timer:
            def __init__(self, seconds, action):
                self.action = action
            def start(self):
                self.action()
            def cancel(self):
                events.append('timer_cancelled')
        with patch('companion.planner.http.client.HTTPConnection', Connection), patch('companion.planner.threading.Timer', Timer):
            with self.assertRaises(PlanError):
                local_transport(b'{}')
        self.assertEqual(events, ['shutdown', 'socket_closed', 'timer_cancelled', 'connection_closed'])


if __name__ == '__main__':
    unittest.main()
