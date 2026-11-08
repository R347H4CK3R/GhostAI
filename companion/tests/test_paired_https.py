"""Real disposable loopback TLS; never a LAN deployment or real credentials."""
import asyncio
import datetime
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid
from cryptography import x509
from cryptography.hazmat.primitives import hashes,serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID,ExtendedKeyUsageOID
from companion.paired_host import PairedHost
from companion import paired_protocol as wire
from companion.autonomy import DEFAULT_LIMITS
from companion.tests.test_paired_protocol import HOST,b64,public,sign
from companion.tests.test_paired_host import PROJECT,encoded,private_state
from companion.tests.test_autonomy import plan,read,complete
SPEC=importlib.util.find_spec('companion.paired_https')
if SPEC:from companion.paired_https import PairedHTTPSService

def synthetic_tls(directory):
    key=ec.generate_private_key(ec.SECP256R1());name=x509.Name([x509.NameAttribute(NameOID.COMMON_NAME,'Synthetic test only')]);now=datetime.datetime.now(datetime.timezone.utc)
    cert=(x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(x509.random_serial_number()).not_valid_before(now-datetime.timedelta(minutes=1)).not_valid_after(now+datetime.timedelta(days=1)).add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address('10.1.2.3'))]),critical=False).add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),critical=False).add_extension(x509.BasicConstraints(ca=False,path_length=None),critical=True).sign(key,hashes.SHA256()))
    certificate=directory/'synthetic-cert.pem';private=directory/'synthetic-key.pem'
    certificate.write_bytes(cert.public_bytes(serialization.Encoding.PEM));private.write_bytes(key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()))
    server=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);server.minimum_version=ssl.TLSVersion.TLSv1_2;server.load_cert_chain(certificate,private)
    return server,ssl.create_default_context(cafile=str(certificate)),cert.fingerprint(hashes.SHA256()).hex()

class HTTPSIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.assertIsNotNone(SPEC,'HTTPS adapter must be reconstructed')
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name).resolve()
        self.state=self.root/'state';private_state(self.state);self.work=self.root/'work';self.work.mkdir();(self.work/'input.txt').write_text('Synthetic HTTPS observation.')
        project=dict(project_id=PROJECT,label='Synthetic',workspace=str(self.work),permission_revision=1,model='local-model',trust_local_model=True,limits=dict(DEFAULT_LIMITS))
        self.host=PairedHost(self.state,HOST,[project],create=True);self.addCleanup(self.host.close)
        self.server_context,self.client_context,pin=synthetic_tls(self.root)
        self.identity=dict(v=1,host_id=HOST,origin='https://10.1.2.3:8443',tls_leaf_sha256=pin)
        self.service=PairedHTTPSService(self.host,self.identity);await self.service.start(self.server_context,loopback_test=True,dispatch=False);self.addAsyncCleanup(self.service.close)
        self.port=self.service.port;self.key=ec.derive_private_key(1,ec.SECP256R1());self.sequence=0;self.device=None
    async def exchange(self,request,*,context=None,name='10.1.2.3'):
        reader,writer=await asyncio.open_connection('127.0.0.1',self.port,ssl=context or self.client_context,server_hostname=name)
        try:writer.write(request);await writer.drain();response=await asyncio.wait_for(reader.read(),3)
        finally:writer.close();await writer.wait_closed()
        head,raw=response.split(b'\r\n\r\n',1)
        return int(head.split(b' ')[1]),dict(line.lower().split(b': ',1) for line in head.split(b'\r\n')[1:]),raw
    async def post(self,route,body,*,signed=True,extra=(),authority='10.1.2.3:8443',method='POST'):
        raw=encoded(body);headers=[('Host',authority),('Content-Type','application/json'),('Content-Length',str(len(raw))),('Connection','close')]
        if signed:
            self.sequence+=1;rid=str(uuid.uuid4());frame=wire.request_message(HOST,self.device,self.sequence,rid,route,raw)
            headers += [('X-Veyra-Host',HOST),('X-Veyra-Device',self.device),('X-Veyra-Sequence',str(self.sequence)),('X-Veyra-Request',rid),('X-Veyra-Signature',sign(self.key,frame))]
        request=f'{method} {route} HTTP/1.1\r\n'.encode()+b''.join(f'{k}: {v}\r\n'.encode() for k,v in headers+list(extra))+b'\r\n'+raw
        status,headers,response=await self.exchange(request);return status,headers,json.loads(response)
    def begin_body(self):
        invite=self.host.create_invitation([PROJECT]);body=dict(v=1,host_id=HOST,invite_id=invite['invite_id'],client_nonce=b64(os.urandom(32)),device_name='Synthetic TLS phone',client_public_key=public(self.key))
        frame=wire.pair_message(body);body['proof']=b64(hmac.digest(wire.decode64(invite['invite_secret'],32),frame,'sha256'));body['signature']=sign(self.key,frame+body['proof'].encode()+b'\n');return body
    async def enroll(self):
        status,_,result=await self.post('/v1/pair/begin',self.begin_body(),signed=False);self.assertEqual(status,200)
        self.device=result['device_id'];self.host.approve_device(self.device,result['safety_code'])
    async def test_default_dispatcher_executes_signed_job_and_result_then_revocation(self):
        await self.service.close();replies=iter([plan(read()),complete('Synthetic HTTPS observation.')])
        def model(_):return encoded(dict(done=True,response=json.dumps(next(replies))))
        self.service=PairedHTTPSService(self.host,self.identity,job_transport=model);await self.service.start(self.server_context,loopback_test=True);self.addAsyncCleanup(self.service.close);self.port=self.service.port
        await self.enroll();body=dict(v=1,project_id=PROJECT,submission_id=str(uuid.uuid4()),goal='Read input.txt',requested_write_paths=[],limits=dict(DEFAULT_LIMITS))
        status,headers,accepted=await self.post('/v1/jobs/submit',body);self.assertEqual(status,202);self.assertEqual(headers[b'cache-control'],b'no-store')
        for _ in range(50):
            status,_,result=await self.post('/v1/jobs/get',dict(v=1,project_id=PROJECT,job_id=accepted['job_id']))
            self.assertEqual(status,200,result)
            if result['status']=='completed':break
            await asyncio.sleep(.02)
        self.assertEqual(result['summary'],'Synthetic HTTPS observation.');self.assertEqual(result['counters']['tool_calls'],1)
        self.host.revoke_device(self.device);self.assertEqual((await self.post('/v1/pair/status',{'v':1}))[0],403)
    async def test_trust_hostname_and_plaintext_fail_without_enrollment(self):
        for context,name in ((ssl.create_default_context(),'10.1.2.3'),(self.client_context,'10.1.2.4')):
            with self.assertRaises(ssl.SSLCertVerificationError):await self.exchange(b'PRIVATE-MARKER',context=context,name=name)
        reader,writer=await asyncio.open_connection('127.0.0.1',self.port);writer.write(b'POST /v1/pair/begin HTTP/1.1\r\n\r\n');await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(),2),b'');writer.close();await writer.wait_closed()
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM devices').fetchone()[0],0)
    async def test_strict_header_route_and_body_boundaries(self):
        for arguments in ({'authority':'evil.invalid'},{'extra':[('Host','10.1.2.3:8443')]},{'extra':[('Origin','https://evil.invalid')]},{'extra':[('Content-Encoding','gzip')]},{'extra':[('Expect','100-continue')]},{'method':'GET'}):
            status,_,result=await self.post('/v1/pair/begin',{},signed=False,**arguments);self.assertIn(status,(400,403,405,417));self.assertEqual(set(result),{'v','error'})
        for route in ('/v1/pair/approve','/v1/pair/%62egin','/v1/pair/begin?x=1','http://10.1.2.3:8443/v1/pair/begin'):
            self.assertEqual((await self.post(route,{},signed=False))[0],404)
        self.assertEqual((await self.post('/v1/pair/begin',{'x':'x'*4096},signed=False))[0],413)
    async def test_parser_errors_do_not_echo_secrets(self):
        for request in (b'PRIVATE-MARKER / HTTP/1.1\r\nHost: 10.1.2.3:8443\r\n\r\n',b'POST /v1/pair/begin HTTP/1.1\r\nHost: 10.1.2.3:8443\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}'):
            status,headers,raw=await self.exchange(request);self.assertEqual(status,400);self.assertNotIn(b'PRIVATE-MARKER',raw);self.assertEqual(headers[b'cache-control'],b'no-store');self.assertEqual(json.loads(raw)['error']['code'],'invalid_request')
    async def test_buffered_partial_or_complete_pipeline_is_rejected_before_pairing(self):
        for suffix in (b'GET / HTTP/1.1\r\nHost: 10.1.2.3:8443\r\n\r\n',b'GET /incomplete'):
            raw=encoded(self.begin_body());request=b'POST /v1/pair/begin HTTP/1.1\r\nHost: 10.1.2.3:8443\r\nContent-Type: application/json\r\nContent-Length: '+str(len(raw)).encode()+b'\r\n\r\n'+raw+suffix
            self.assertEqual((await self.exchange(request))[0],400)
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM devices').fetchone()[0],0)
    async def test_default_port_authority_accepts_only_identical_ip_spellings(self):
        self.service.configured_port=443;self.service.authority='10.1.2.3:443'
        for authority in ('10.1.2.3','10.1.2.3:443'):self.assertEqual((await self.post('/v1/pair/begin',{},signed=False,authority=authority))[0],403)
        for authority in ('10.1.2.4','10.1.2.3:0443','10.1.2.3:8443'):self.assertEqual((await self.post('/v1/pair/begin',{},signed=False,authority=authority))[0],400)
    async def test_connection_admission_bounded_before_tls(self):
        sockets=[]
        with patch('companion.paired_https.HANDSHAKE_SECONDS',.3):
            for _ in range(10):sockets.append(await asyncio.open_connection('127.0.0.1',self.port))
            for _ in range(20):
                if len(self.service.connections)==8:break
                await asyncio.sleep(.005)
            self.assertEqual(len(self.service.connections),8)
            for reader,writer in sockets:
                self.assertEqual(await asyncio.wait_for(reader.read(),1),b'');writer.close();await writer.wait_closed()
        await self.enroll()
    async def test_slow_incomplete_body_expires_without_mutation(self):
        with patch('companion.paired_https.REQUEST_SECONDS',.1):
            reader,writer=await asyncio.open_connection('127.0.0.1',self.port,ssl=self.client_context,server_hostname='10.1.2.3')
            writer.write(b'POST /v1/pair/begin HTTP/1.1\r\nHost: 10.1.2.3:8443\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{}');await writer.drain()
            data=await asyncio.wait_for(reader.read(),2);self.assertTrue(data==b'' or b'408' in data);writer.close();await writer.wait_closed()
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM devices').fetchone()[0],0)
    async def test_timed_out_worker_retains_device_slot_until_actual_completion(self):
        await self.enroll();release=threading.Event();original=self.host.handle
        def blocked(*args):release.wait(3);return original(*args)
        try:
            with patch('companion.paired_https.REQUEST_SECONDS',.15),patch.object(self.host,'handle',side_effect=blocked):
                for _ in range(2):
                    try:await self.post('/v1/pair/status',{'v':1})
                    except (ValueError,ConnectionError):pass
                self.assertEqual(self.service.active_devices[self.device],2)
                self.assertEqual((await self.post('/v1/pair/status',{'v':1}))[0],429)
                self.assertEqual(self.service.active_devices[self.device],2)
        finally:release.set()
        for _ in range(100):
            if not self.service.active_devices:break
            await asyncio.sleep(.01)
        self.assertFalse(self.service.active_devices)
    async def test_disconnected_requests_cannot_enqueue_unbounded_host_work(self):
        release=threading.Event();count=0;lock=threading.Lock()
        def blocked(*_):
            nonlocal count
            with lock:count+=1
            release.wait(5);return 403,dict(v=1,error=dict(code='unauthorized',request_id=None))
        request=b'POST /v1/pair/begin HTTP/1.1\r\nHost: 10.1.2.3:8443\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}'
        try:
            with patch.object(self.host,'handle',side_effect=blocked):
                for index in range(12):
                    reader,writer=await asyncio.open_connection('127.0.0.1',self.port,ssl=self.client_context,server_hostname='10.1.2.3');writer.write(request);await writer.drain()
                    for _ in range(100):
                        if len(self.service.pending_work)>=min(index+1,8):break
                        await asyncio.sleep(.001)
                    writer.close();await writer.wait_closed()
                self.assertEqual(count,8);self.assertEqual(len(self.service.pending_work),8)
        finally:release.set()
        for _ in range(100):
            if not self.service.pending_work:break
            await asyncio.sleep(.01)
        self.assertFalse(self.service.pending_work)
    async def test_unexpected_dispatcher_failure_refuses_new_jobs(self):
        await self.enroll()
        with patch('companion.paired_https.run_next',side_effect=AttributeError('synthetic failure')):
            self.service.dispatch_task=asyncio.create_task(self.service._dispatch())
            await asyncio.gather(self.service.dispatch_task,return_exceptions=True)
        self.assertTrue(self.service.dispatch_failed)
        body=dict(v=1,project_id=PROJECT,submission_id=str(uuid.uuid4()),goal='Synthetic',requested_write_paths=[],limits=dict(DEFAULT_LIMITS))
        self.assertEqual((await self.post('/v1/jobs/submit',body))[0],503)
        with self.host.transaction() as db:self.assertEqual(db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
