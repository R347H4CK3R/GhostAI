"""Opt-in HTTPS adapter using pinned aiohttp. Nothing listens on import.

Bound accepted connections before TLS, fixed POST routes, no request logging,
redirect, decompression or HTTP fallback. All tests bind ephemeral loopback only.
"""
import asyncio
from collections import Counter,deque
from concurrent.futures import ThreadPoolExecutor
import contextlib
import json
import logging
import re
import socket
import sqlite3
import ssl
import sys
from aiohttp import web,HttpVersion11
from aiohttp.web_protocol import RequestHandler
from . import paired_protocol as wire
from .paired_jobs import run_next

MAX_CONNECTIONS=8
HANDSHAKE_SECONDS=5
REQUEST_SECONDS=10
RATE_PER_MINUTE=120

def response(status,value):
    result=web.Response(status=status,body=json.dumps(value,separators=(',',':')).encode(),content_type='application/json',headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})
    result.force_close();return result

def failure(status,code='invalid_request'):return response(status,dict(v=1,error=dict(code=code,request_id=None)))

class BoundedRequestHandler(RequestHandler):
    def __init__(self,manager):
        logger=logging.Logger('veyra.paired.redacted');logger.disabled=True
        super().__init__(manager,loop=asyncio.get_running_loop(),access_log=None,logger=logger,debug=False,max_line_size=4096,max_field_size=4096,max_headers=32,read_bufsize=16384,auto_decompress=False,keepalive_timeout=REQUEST_SECONDS,lingering_time=0)
        self.closed=asyncio.get_running_loop().create_future();self.deadline=None;self.received_bytes=0;self.prefix=bytearray()
    def data_received(self,data):
        self.received_bytes+=len(data)
        if len(self.prefix)<16384:self.prefix.extend(data[:16384-len(self.prefix)])
        super().data_received(data)
    def connection_made(self,transport):
        super().connection_made(transport);self.deadline=asyncio.get_running_loop().call_later(REQUEST_SECONDS,transport.abort)
    def connection_lost(self,exc):
        if self.deadline:self.deadline.cancel()
        super().connection_lost(exc)
        if not self.closed.done():self.closed.set_result(None)
    def handle_error(self,request,status=500,exc=None,message=None):
        return failure(400 if status<500 else 500,'invalid_request' if status<500 else 'state_unavailable')

class PairedHTTPSService:
    def __init__(self,host,identity,*,job_transport=None):
        if sys.version_info[:2]<(3,11):raise wire.ProtocolError('python_3_11_required')
        from .paired_identity import parse_origin
        wire.exact(identity,('v','host_id','origin','tls_leaf_sha256'));wire.version(identity['v']);wire.identifier(identity['host_id'])
        if identity['host_id']!=host.host_id or type(identity['tls_leaf_sha256']) is not str or not re.fullmatch('[0-9a-f]{64}',identity['tls_leaf_sha256']):raise wire.ProtocolError('state_unavailable')
        self.address,self.configured_port=parse_origin(identity['origin']);self.authority=f'{self.address}:{self.configured_port}'
        self.host=host;self.identity=dict(identity);self.job_transport=job_transport
        self.socket=None;self.accept_task=None;self.dispatch_task=None;self.stopping=False;self.dispatch_failed=False
        self.connections=set();self.protocols=set();self.slots=asyncio.Semaphore(MAX_CONNECTIONS);self.active_devices=Counter()
        self.work_slots=asyncio.Semaphore(MAX_CONNECTIONS);self.pending_work=set();self.executor=ThreadPoolExecutor(max_workers=MAX_CONNECTIONS,thread_name_prefix='veyra-request')
        self.attempts=deque();self.wakeup=asyncio.Event();self.port=None;self.manager=web.Server(self.handle,handler_cancellation=True)
    async def start(self,context,*,loopback_test=False,dispatch=True):
        if self.socket is not None or self.stopping:raise wire.ProtocolError('state_unavailable')
        if not isinstance(context,ssl.SSLContext) or context.protocol!=ssl.PROTOCOL_TLS_SERVER or context.minimum_version<ssl.TLSVersion.TLSv1_2:raise wire.ProtocolError('state_unavailable')
        bind=('127.0.0.1',0) if loopback_test else (self.address,self.configured_port)
        listener=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
        try:listener.setblocking(False);listener.bind(bind);listener.listen(MAX_CONNECTIONS)
        except BaseException:listener.close();raise
        self.socket=listener;self.port=listener.getsockname()[1];self.accept_task=asyncio.create_task(self._accept(context))
        if dispatch:self.dispatch_task=asyncio.create_task(self._dispatch())
    async def _accept(self,context):
        loop=asyncio.get_running_loop()
        while not self.stopping:
            await self.slots.acquire()
            try:connection,_=await loop.sock_accept(self.socket)
            except BaseException:self.slots.release();raise
            connection.setblocking(False);task=asyncio.create_task(self._connection(connection,context));self.connections.add(task);task.add_done_callback(self.connections.discard)
    async def _connection(self,connection,context):
        protocol=None;transport=None
        try:
            protocol=BoundedRequestHandler(self.manager);self.protocols.add(protocol)
            transport,_=await asyncio.get_running_loop().connect_accepted_socket(lambda:protocol,connection,ssl=context,ssl_handshake_timeout=HANDSHAKE_SECONDS,ssl_shutdown_timeout=1)
            await protocol.closed
        except (OSError,ssl.SSLError,asyncio.TimeoutError,ConnectionError):pass
        finally:
            if transport is not None:transport.abort()
            connection.close()
            if protocol is not None:self.protocols.discard(protocol)
            self.slots.release()
    async def handle(self,request):
        device=None;acquired_device=False;submitted_work=False
        def release_device():
            nonlocal acquired_device
            if acquired_device:
                self.active_devices[device]-=1
                if not self.active_devices[device]:del self.active_devices[device]
                acquired_device=False
        try:
            if not request.secure:return failure(403,'unauthorized')
            if request.method!='POST':return failure(405)
            if request.raw_path not in wire.ROUTES|{'/v1/pair/begin'}:return failure(404,'not_found')
            if request.version!=HttpVersion11:return failure(400)
            if self.dispatch_failed and request.raw_path=='/v1/jobs/submit':return failure(503,'state_unavailable')
            pairs=[(name.decode('ascii'),value.decode('ascii')) for name,value in request.raw_headers]
            if sum(len(k)+len(v)+4 for k,v in pairs)>8192:return failure(431)
            grouped={}
            for name,value in pairs:grouped.setdefault(name.lower(),[]).append(value)
            authorities=([self.authority],[self.address]) if self.configured_port==443 else ([self.authority],)
            if grouped.get('host') not in authorities or grouped.get('content-type')!=['application/json']:return failure(400)
            if any(name in grouped for name in ('origin','transfer-encoding','content-encoding','expect','upgrade')):return failure(400)
            lengths=grouped.get('content-length',[])
            if len(lengths)!=1 or not re.fullmatch('0|[1-9][0-9]{0,7}',lengths[0]):return failure(400)
            length=int(lengths[0]);limit=wire.MAX_PAIR if request.raw_path=='/v1/pair/begin' else wire.MAX_BODY
            if length>limit:return failure(413)
            security=[(name,value) for name,value in pairs if name.lower().startswith('x-veyra-')]
            if request.raw_path=='/v1/pair/begin':
                if security:return failure(400)
            else:
                auth=wire.auth_headers(security);device=auth['device']
                if self.active_devices[device]>=2:return failure(429,'capacity')
                self.active_devices[device]+=1;acquired_device=True
            now=asyncio.get_running_loop().time()
            while self.attempts and self.attempts[0]<=now-60:self.attempts.popleft()
            if len(self.attempts)>=RATE_PER_MINUTE:return failure(429,'capacity')
            self.attempts.append(now)
            async with asyncio.timeout(REQUEST_SECONDS):
                raw=await request.content.readexactly(length)
                canonical=(f'{request.method} {request.raw_path} HTTP/1.1\r\n'.encode('ascii')+b''.join(name+b': '+value+b'\r\n' for name,value in request.raw_headers)+b'\r\n')
                protocol=request.protocol
                # aiohttp remains the parser. Prefix equality prevents omitted
                # header spaces from offsetting already-buffered extra bytes.
                if not request.content.at_eof() or bytes(protocol.prefix[:len(canonical)])!=canonical or protocol.received_bytes!=len(canonical)+length:return failure(400)
                await self.work_slots.acquire()
                if self.stopping:self.work_slots.release();return failure(503,'state_unavailable')
                loop=asyncio.get_running_loop()
                try:work=self.executor.submit(self.host.handle,request.raw_path,raw,security)
                except BaseException:self.work_slots.release();raise
                submitted_work=True;self.pending_work.add(work)
                def completed(future):
                    self.pending_work.discard(future);self.work_slots.release();release_device()
                work.add_done_callback(lambda future:loop.call_soon_threadsafe(completed,future))
                # A disconnected await does not stop its worker. Admission is
                # retained until the actual concurrent future completes.
                status,value=await asyncio.shield(asyncio.wrap_future(work))
            if status==202:self.wakeup.set()
            return response(status,value)
        except (wire.ProtocolError,UnicodeError,ValueError,asyncio.IncompleteReadError):return failure(400)
        except asyncio.TimeoutError:return failure(408)
        except (OSError,RuntimeError):return failure(503,'state_unavailable')
        finally:
            if not submitted_work:release_device()
    async def _dispatch(self):
        try:
            while not self.stopping:
                result=await asyncio.to_thread(run_next,self.host,transport=self.job_transport)
                if result is not None:continue
                self.wakeup.clear()
                try:await asyncio.wait_for(self.wakeup.wait(),.5)
                except asyncio.TimeoutError:pass
        except asyncio.CancelledError:
            if not self.stopping:self.dispatch_failed=True
            raise
        except Exception:
            self.dispatch_failed=True  # Never acknowledge more work as executable.
    async def close(self):
        if self.stopping:return
        self.stopping=True
        if self.accept_task:
            self.accept_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):await self.accept_task
        if self.socket:self.socket.close()
        for protocol in list(self.protocols):
            if protocol.transport:protocol.transport.abort()
        for task in list(self.connections):task.cancel()
        await asyncio.gather(*list(self.connections),return_exceptions=True)
        if self.pending_work:await asyncio.gather(*(asyncio.wrap_future(work) for work in list(self.pending_work)),return_exceptions=True)
        self.executor.shutdown(wait=True,cancel_futures=False)
        if self.dispatch_task:
            with self.host.transaction() as db:db.execute("UPDATE jobs SET cancel_requested=1 WHERE status IN ('starting','running')")
            self.wakeup.set()
            with contextlib.suppress(asyncio.CancelledError):await self.dispatch_task
        await self.manager.shutdown(timeout=1)
