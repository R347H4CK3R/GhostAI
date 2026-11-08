"""Version-one signed read-only job protocol. No transport or credentials."""
import base64
import hashlib
import json
import re
import unicodedata
import uuid
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils

MAX_PAIR=4096
MAX_BODY=262144
MAX_SEQUENCE=2**63-1
ORDER=0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
ROUTES=frozenset(('/v1/pair/status','/v1/jobs/submit','/v1/jobs/get','/v1/jobs/cancel'))

class ProtocolError(ValueError):
    def __init__(self,code='invalid_request'):
        self.code=code;super().__init__(code)

def exact(value,keys):
    if type(value) is not dict or set(value)!=set(keys):raise ProtocolError()
    return value

def version(value):
    if type(value) is not int or value!=1:raise ProtocolError()
    return value

def integer(value,maximum=MAX_SEQUENCE):
    if type(value) is not int or not 1<=value<=maximum:raise ProtocolError()
    return value

def identifier(value):
    try:
        if type(value) is not str or len(value)!=36 or str(uuid.UUID(value))!=value:raise ValueError()
    except (ValueError,AttributeError):raise ProtocolError() from None
    return value

def text(value,maximum,*,scalars=None):
    try:
        if type(value) is not str or not value.strip() or len(value.encode('utf-8'))>maximum or (scalars is not None and len(value)>scalars):raise ValueError()
    except (ValueError,UnicodeError):raise ProtocolError() from None
    return value

def device_name(value):
    text(value,256,scalars=64)
    if any(unicodedata.category(char).startswith('C') for char in value):raise ProtocolError()
    return value

def encode64(raw):return base64.urlsafe_b64encode(raw).rstrip(b'=').decode('ascii')
def decode64(value,size):
    if type(value) is not str or not re.fullmatch('[A-Za-z0-9_-]+',value):raise ProtocolError()
    try:raw=base64.b64decode(value+'='*((-len(value))%4),altchars=b'-_',validate=True)
    except (ValueError,UnicodeError):raise ProtocolError() from None
    if len(raw)!=size or encode64(raw)!=value:raise ProtocolError()
    return raw

def load_object(raw,maximum=MAX_BODY):
    if type(raw) is not bytes or len(raw)>maximum:raise ProtocolError()
    def pairs(items):
        result={}
        for key,value in items:
            if key in result:raise ProtocolError()
            result[key]=value
        return result
    def reject(_):raise ProtocolError()
    try:value=json.loads(raw.decode('utf-8'),object_pairs_hook=pairs,parse_float=reject,parse_constant=reject)
    except (ValueError,UnicodeError,RecursionError):raise ProtocolError() from None
    count=0
    def check(item,depth=0):
        nonlocal count
        count+=1
        if depth>24 or count>10000:raise ProtocolError()
        if type(item) is str:
            try:item.encode('utf-8')
            except UnicodeError:raise ProtocolError() from None
        if type(item) is int and not -MAX_SEQUENCE<=item<=MAX_SEQUENCE:raise ProtocolError()
        if type(item) is dict:
            for key,child in item.items():check(key,depth+1);check(child,depth+1)
        if type(item) is list:
            for child in item:check(child,depth+1)
    check(value)
    if type(value) is not dict:raise ProtocolError()
    return value

def public_key(value):
    raw=decode64(value,65)
    if raw[0]!=4:raise ProtocolError()
    try:key=ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(),raw)
    except ValueError:raise ProtocolError() from None
    if key.public_bytes(serialization.Encoding.X962,serialization.PublicFormat.UncompressedPoint)!=raw:raise ProtocolError()
    return key

def verify_signature(public,signature,message):
    key=public_key(public);raw=decode64(signature,64)
    r,s=int.from_bytes(raw[:32],'big'),int.from_bytes(raw[32:],'big')
    if not 1<=r<ORDER or not 1<=s<=ORDER//2:raise ProtocolError('unauthorized')
    try:key.verify(utils.encode_dss_signature(r,s),message,ec.ECDSA(hashes.SHA256()))
    except (InvalidSignature,ValueError):raise ProtocolError('unauthorized') from None

def pair_message(body):
    version(body['v']);identifier(body['host_id']);identifier(body['invite_id'])
    decode64(body['client_nonce'],32);public_key(body['client_public_key']);device_name(body['device_name'])
    return ('VEYRA-PAIR-V1\n'+body['host_id']+'\n'+body['invite_id']+'\n'+body['client_nonce']+'\n'+body['client_public_key']+'\n'+hashlib.sha256(body['device_name'].encode('utf-8')).hexdigest()+'\n').encode('utf-8')

def request_message(host,device,sequence,request,route,body):
    identifier(host);identifier(device);identifier(request);integer(sequence)
    if route not in ROUTES or type(body) is not bytes or len(body)>MAX_BODY:raise ProtocolError()
    return f'VEYRA-REQUEST-V1\n{host}\n{device}\n{sequence}\n{request}\nPOST\n{route}\n{hashlib.sha256(body).hexdigest()}\n'.encode('ascii')

def auth_headers(pairs):
    values={}
    for key,value in pairs:
        if type(key) is not str or type(value) is not str:raise ProtocolError()
        name=key.lower()
        if name in values:raise ProtocolError()
        values[name]=value
    names={'x-veyra-'+name for name in ('host','device','sequence','request','signature')}
    if set(values)!=names:raise ProtocolError()
    result={key[8:]:value for key,value in values.items()}
    for name in ('host','device','request'):identifier(result[name])
    seq=result['sequence']
    if not re.fullmatch('[1-9][0-9]{0,18}',seq):raise ProtocolError()
    result['sequence']=integer(int(seq));decode64(result['signature'],64)
    return result
