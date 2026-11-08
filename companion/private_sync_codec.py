"""Unwired, read-only v1 primitives. No portable canonical record encoder yet.

Keep imported Foundation seconds, never round-trip identity through Unix time.
Conflict callers must supply the *exact native canonical bytes*. A generic JSON
encoder is not a substitute. These helpers do not validate or merge vaults, read
credentials, perform I/O, or authorize a remote writer.
"""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
import re
import struct
import uuid

HEADER = b'VEYRA-SYNC\x00\x00\x00\x01'
MAXIMUM_DOCUMENT_BYTES = 8 * 1024 * 1024
MAXIMUM_TOMBSTONES = 20_000
_REFERENCE_OFFSET = 978_307_200
_UUID = re.compile(r'[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\Z')


@dataclass(frozen=True)
class ReferenceDate:
    """Lossless imported wire date. Unix seconds are only a display/projection."""
    bits_hex: str

    def __post_init__(self):
        if not isinstance(self.bits_hex, str) or not re.fullmatch('[0-9a-f]{16}', self.bits_hex):
            raise ValueError('Invalid reference date bits')
        value = struct.unpack('>d', bytes.fromhex(self.bits_hex))[0]
        unix = value + _REFERENCE_OFFSET
        if not math.isfinite(value) or not 0 <= unix <= 253_402_300_799:
            raise ValueError('Invalid reference date')

    @classmethod
    def from_json(cls, value: object) -> ReferenceDate:
        if type(value) not in (int, float):
            raise ValueError('Invalid reference date')
        try:
            return cls(struct.pack('>d', float(value)).hex())
        except (OverflowError, struct.error) as exc:
            raise ValueError('Invalid reference date') from exc

    @classmethod
    def from_bits(cls, bits: str) -> ReferenceDate:
        return cls(bits)

    @property
    def reference_seconds(self) -> float:
        return struct.unpack('>d', bytes.fromhex(self.bits_hex))[0]

    @property
    def unix_seconds(self) -> float:
        return self.reference_seconds + _REFERENCE_OFFSET


def record_uuid(value: str) -> str:
    if not isinstance(value, str) or not _UUID.fullmatch(value):
        raise ValueError('Invalid record UUID')
    return str(uuid.UUID(value)).upper()


def tombstone(kind: str, identifier: str) -> str:
    if kind not in ('note', 'chat'):
        raise ValueError('Unsupported record kind')
    return kind + ':' + record_uuid(identifier).lower()


def conflict_id(kind: str, original_id: str, native_canonical: bytes) -> str:
    domain = tombstone(kind, original_id)
    if not isinstance(native_canonical, bytes) or not 0 < len(native_canonical) <= MAXIMUM_DOCUMENT_BYTES:
        raise ValueError('Exact native canonical bytes required')
    digest = bytearray(hashlib.sha256(domain.encode('utf-8') + native_canonical).digest()[:16])
    digest[6] = (digest[6] & 0x0f) | 0x50
    digest[8] = (digest[8] & 0x3f) | 0x80
    result = str(uuid.UUID(bytes=bytes(digest)))
    if result == original_id.lower():
        raise ValueError('Conflicting identity')
    return result


def restored_id(kind: str, original_id: str, markers) -> str:
    value = record_uuid(original_id).lower()
    tombstone(kind, value)
    deleted = set()
    # Bound iteration even when the caller supplies a generator.
    for index, marker in enumerate(markers):
        if index >= MAXIMUM_TOMBSTONES or not isinstance(marker, str):
            raise ValueError('Invalid deletion markers')
        parts = marker.split(':')
        if len(parts) != 2 or tombstone(*parts) != marker or marker in deleted:
            raise ValueError('Invalid deletion markers')
        deleted.add(marker)
    visited = set()
    while tombstone(kind, value) in deleted:
        if value in visited or len(visited) >= MAXIMUM_TOMBSTONES:
            raise ValueError('Restoration capacity exceeded')
        visited.add(value)
        domain = 'Veyra explicit import restoration v1\0' + kind + '\0' + value
        digest = bytearray(hashlib.sha256(domain.encode('utf-8')).digest()[:16])
        digest[6] = (digest[6] & 0x0f) | 0x80
        digest[8] = (digest[8] & 0x3f) | 0x80
        value = str(uuid.UUID(bytes=bytes(digest)))
    return value


def strict_json(raw: bytes):
    """Bounded untyped JSON, NOT a document decoder or record canonicalizer."""
    if not isinstance(raw, bytes) or len(raw) > MAXIMUM_DOCUMENT_BYTES:
        raise ValueError('Invalid JSON size')
    try:
        text = raw.decode('utf-8')
        depth = 0
        quoted = escaped = False
        for character in text:
            if quoted:
                if escaped:
                    escaped = False
                elif character == '\\':
                    escaped = True
                elif character == '"':
                    quoted = False
            elif character == '"':
                quoted = True
            elif character in '[{':
                depth += 1
                if depth > 64:
                    raise ValueError('JSON nesting limit exceeded')
            elif character in ']}':
                depth -= 1
        def pairs(items):
            result = {}
            for key, value in items:
                if key in result:
                    raise ValueError('Duplicate JSON key')
                result[key] = value
            return result
        def constant(_):
            raise ValueError('Nonfinite JSON number')
        # Foundation consumes binary64 dates. Preserve a literal -0's sign too.
        result = json.loads(text, object_pairs_hook=pairs, parse_constant=constant,
                            parse_int=lambda token: -0.0 if token == '-0' else int(token))
        def validate(value):
            if isinstance(value, str):
                value.encode('utf-8')  # Refuse unpaired surrogates.
            elif isinstance(value, float) and not math.isfinite(value):
                raise ValueError('Nonfinite JSON number')
            elif isinstance(value, list):
                for item in value:
                    validate(item)
            elif isinstance(value, dict):
                for key, item in value.items():
                    validate(key); validate(item)
        validate(result)
        return result
    except (UnicodeError, RecursionError, OverflowError) as exc:
        raise ValueError('Invalid JSON') from exc


def passphrase_utf8(value: str) -> bytes:
    if not isinstance(value, str) or not 0 < len(value) <= 4096:
        raise ValueError('Invalid passphrase')
    try:
        raw = value.encode('utf-8') if isinstance(value, str) else b''
    except UnicodeError as exc:
        raise ValueError('Invalid passphrase') from exc
    if not 0 < len(raw) <= 4096:
        raise ValueError('Invalid passphrase')
    return raw


def decrypt_remote_payload(encrypted: bytes, passphrase: str) -> bytes:
    """Authenticate a bounded remote envelope. Result still needs typed validation.

    No journal entry point is exposed: a journal must not become a remote vault.
    Keep this optional dependency lazy so the offline CLI remains unchanged.
    """
    if (not isinstance(encrypted, bytes) or not 58 <= len(encrypted) <= MAXIMUM_DOCUMENT_BYTES + 58
            or not encrypted.startswith(HEADER)):
        raise ValueError('Invalid remote envelope')
    password = passphrase_utf8(passphrase)
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.exceptions import InvalidTag
    key = hashlib.pbkdf2_hmac('sha256', password, encrypted[14:30], 600_000, 32)
    try:
        return AESGCM(key).decrypt(encrypted[30:42], encrypted[42:], encrypted[:42])
    except InvalidTag as exc:
        raise ValueError('Remote envelope authentication failed') from exc
