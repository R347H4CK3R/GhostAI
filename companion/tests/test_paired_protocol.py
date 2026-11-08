"""Synthetic fixed-key signing and strict wire contract; no real enrollment."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

HOST='11111111-1111-4111-8111-111111111111'
DEVICE='33333333-3333-4333-8333-333333333333'
INVITE='22222222-2222-4222-8222-222222222222'
REQUEST='44444444-4444-4444-8444-444444444444'
ORDER=0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
SPEC=importlib.util.find_spec('companion.paired_protocol')
if SPEC: from companion import paired_protocol as wire

def b64(raw): return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')
def public(key): return b64(key.public_key().public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint))
def sign(key,raw):
    r,s=utils.decode_dss_signature(key.sign(raw,ec.ECDSA(hashes.SHA256())))
    return b64(r.to_bytes(32,'big')+min(s,ORDER-s).to_bytes(32,'big'))

class WireTests(unittest.TestCase):
    def setUp(self): self.assertIsNotNone(SPEC,'paired protocol must be reconstructed')
    def test_request_frame_commits_exact_body_and_route(self):
        raw=b'{"v":1}'
        expected=f'VEYRA-REQUEST-V1\n{HOST}\n{DEVICE}\n7\n{REQUEST}\nPOST\n/v1/pair/status\n{hashlib.sha256(raw).hexdigest()}\n'.encode()
        self.assertEqual(wire.request_message(HOST,DEVICE,7,REQUEST,'/v1/pair/status',raw),expected)
        self.assertNotEqual(wire.request_message(HOST,DEVICE,7,REQUEST,'/v1/jobs/get',raw),expected)
    def test_pair_unicode_uses_exact_utf8_digest(self):
        key=ec.derive_private_key(1,ec.SECP256R1())
        body=dict(v=1,host_id=HOST,invite_id=INVITE,client_nonce=b64(bytes(32)),device_name='Café',client_public_key=public(key))
        expected=f'VEYRA-PAIR-V1\n{HOST}\n{INVITE}\n{body["client_nonce"]}\n{public(key)}\n{hashlib.sha256("Café".encode()).hexdigest()}\n'.encode()
        self.assertEqual(wire.pair_message(body),expected)
        body['device_name']='Cafe\u0301';self.assertNotEqual(wire.pair_message(body),expected)
    def test_low_s_signature_verifies_and_rejects_tampering_and_high_s(self):
        key=ec.derive_private_key(1,ec.SECP256R1());signature=sign(key,b'synthetic')
        wire.verify_signature(public(key),signature,b'synthetic')
        raw=wire.decode64(signature,64)
        high=raw[:32]+(ORDER-int.from_bytes(raw[32:],'big')).to_bytes(32,'big')
        for sig,message in ((signature,b'changed'),(b64(high),b'synthetic'),(b64(bytes(64)),b'synthetic')):
            with self.assertRaises(ValueError): wire.verify_signature(public(key),sig,message)
    def test_json_rejects_duplicate_floats_invalid_utf8_and_oversize(self):
        for raw in (b'{"v":1,"v":1}',b'{"v":1,"\\u0076":1}',b'{"v":1.0}',b'{"x":NaN}',b'[]',b'\xff',b'{} {}'):
            with self.subTest(raw=raw),self.assertRaises(ValueError): wire.load_object(raw,100)
        with self.assertRaises(ValueError):wire.load_object(b'{"v":1}',2)
        with self.assertRaises(ValueError):wire.load_object(b'{"x":'+b'['*40+b'0'+b']'*40+b'}',1000)
    def test_canonical_ids_integer_and_base64_reject_ambiguity(self):
        for value in (True,False,0,-1,1.0,'1',2**63):
            with self.assertRaises(ValueError):wire.integer(value)
        for value in (HOST.upper(),'{'+HOST+'}',HOST+'\n'):
            if value!=HOST:
                with self.assertRaises(ValueError):wire.identifier(value)
        for value in (b64(bytes(32))+'=', 'A'*42+'B', '+/'*22):
            with self.assertRaises(ValueError):wire.decode64(value,32)
    def test_security_headers_are_complete_unique_and_canonical(self):
        key=ec.derive_private_key(1,ec.SECP256R1())
        headers=[('X-Veyra-Host',HOST),('X-Veyra-Device',DEVICE),('X-Veyra-Sequence','1'),('X-Veyra-Request',REQUEST),('X-Veyra-Signature',sign(key,b'test'))]
        self.assertEqual(wire.auth_headers(headers)['sequence'],1)
        for bad in (headers[:-1],headers+[headers[0]],headers+[('X-Veyra-Extra','x')],[(k,'01' if k.endswith('Sequence') else v) for k,v in headers]):
            with self.assertRaises(ValueError):wire.auth_headers(bad)
    def test_category_c_device_names_are_rejected(self):
        for name in ('', ' ', 'a\x00','a\n','a\u200d','a\ue000','a\u0378','😀'*65):
            with self.subTest(name=repr(name)),self.assertRaises(ValueError):wire.device_name(name)
        for name in ('Café','设备','😀'*64):self.assertEqual(wire.device_name(name),name)
    def test_shared_fixture_signatures_and_exact_frames_match(self):
        import hmac
        fixture=json.loads((Path(__file__).resolve().parents[2]/'Tests/Fixtures/paired-execution-v1.json').read_text())
        body=dict(v=1,host_id=fixture['host_id'],invite_id=fixture['invite_id'],client_nonce=fixture['client_nonce'],device_name=fixture['device_name'],client_public_key=fixture['client_public_key'])
        frame=wire.pair_message(body);self.assertEqual(frame.decode(),fixture['pair_frame'])
        proof=wire.encode64(hmac.digest(wire.decode64(fixture['invite_secret'],32),frame,'sha256'));self.assertEqual(proof,fixture['proof'])
        signed=frame+proof.encode()+b'\n';self.assertEqual(signed.decode(),fixture['pair_signed_bytes'])
        wire.verify_signature(fixture['client_public_key'],fixture['pair_signature'],signed)
        request=wire.request_message(fixture['host_id'],fixture['device_id'],int(fixture['sequence']),fixture['request_id'],fixture['route'],fixture['request_body'].encode())
        self.assertEqual(request.decode(),fixture['request_frame']);wire.verify_signature(fixture['client_public_key'],fixture['request_signature'],request)
        names=json.loads((Path(__file__).resolve().parents[2]/'Tests/Fixtures/paired-device-names-v1.json').read_text())
        for name in names['accepted']:self.assertEqual(wire.device_name(name),name)
        for name in names['rejected']:
            with self.assertRaises(ValueError):wire.device_name(name)
