"""Unused, pure immutable-note v2 reference; no wire codec or production caller.

Exact UTF-8 payloads and original Foundation-reference binary64 bits are facts,
not edits. UUIDs use canonical lowercase hyphenated text without deriving IDs
from content. Every known ID retains its hash binding after deletion. An opaque
legacy tombstone has no historical binding until a valid body is observed.

Compatible normalized states join by union, subject to every original and result
fitting the same bounds. Failure returns no partial state and never mutates an
input. Hash framing follows the reviewed Swift source; native parity is unrun.

This dependency-free reference uses an explicit conservative Unicode gate, NOT
Python len as Swift Character count. ASCII (including CRLF) is counted exactly.
Non-ASCII is accepted only when its scalar count is already within the grapheme
ceiling. Otherwise unsupported_grapheme_boundary requests a future compatible
segmenter, not a judgment that the record is invalid. No text is changed.
"""
from __future__ import annotations

from dataclasses import dataclass, fields
import hashlib
import math
import re
import struct
import uuid

CONTENT_DOMAIN = b'Veyra immutable note payload v2\0'
UINT64_MAX = (1 << 64) - 1
INT64_MAX = (1 << 63) - 1
_UUID = re.compile(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\Z')


class NoteStateError(ValueError):
    """Typed fail-closed result with a stable code and optional ID/key/field."""
    def __init__(self, code: str, detail=None):
        self.code, self.detail = code, detail
        super().__init__(code if detail is None else f'{code}: {detail}')


@dataclass(frozen=True)
class NotePayload:
    project: str
    text: str
    source: str
    saved_at_bits: int


@dataclass(frozen=True)
class NoteRecord:
    id: str
    payload: NotePayload


@dataclass(frozen=True)
class NoteBinding:
    id: str
    content_key: bytes


@dataclass(frozen=True)
class ImmutableNoteStateV2:
    format: str = 'veyra-immutable-notes-v2'
    identity_scheme: str = 'note-payload-tlv-v2'
    records: tuple[NoteRecord, ...] = ()
    bindings: tuple[NoteBinding, ...] = ()
    tombstones: tuple[str, ...] = ()


@dataclass(frozen=True)
class Limits:
    maximum_notes: int = 10_000
    maximum_records: int = 30_000
    maximum_tombstones: int = 20_000
    maximum_document_bytes: int = 8 * 1024 * 1024
    maximum_journal_bytes: int = 17 * 1024 * 1024
    other_records: int = 0
    other_tombstones: int = 0
    other_document_bytes: int = 0
    other_journal_bytes: int = 0


@dataclass(frozen=True)
class Usage:
    notes: int
    retained_bindings: int
    total_records: int
    total_tombstones: int
    note_document_reservation_bytes: int
    note_journal_reservation_bytes: int
    total_document_reservation_bytes: int
    total_journal_reservation_bytes: int


@dataclass(frozen=True)
class Result:
    state: ImmutableNoteStateV2
    usage: Usage


def _require_tuple(value):
    if type(value) is not tuple:
        raise NoteStateError('invalid_collection')


def _uuid_bytes(value):
    if type(value) is not str or not _UUID.fullmatch(value):
        raise NoteStateError('invalid_uuid')
    return uuid.UUID(value).bytes


def _key(value, code='invalid_key'):
    if type(value) is not bytes or len(value) != 32:
        raise NoteStateError(code)
    return value


def _checked_add(a, b):
    value = a + b
    if value > INT64_MAX:
        raise NoteStateError('capacity_arithmetic')
    return value


def _checked_multiply(a, b):
    value = a * b
    if value > INT64_MAX:
        raise NoteStateError('capacity_arithmetic')
    return value


def _payload_bytes(payload):
    if type(payload) is not NotePayload:
        raise NoteStateError('invalid_payload')
    raw = payload.saved_at_bits
    if type(raw) is not int or not 0 <= raw <= UINT64_MAX:
        raise NoteStateError('invalid_date')
    seconds = struct.unpack('>d', struct.pack('>Q', raw))[0]
    if not math.isfinite(seconds) or not -978307200 <= seconds <= 252423993599:
        raise NoteStateError('invalid_date')
    values = (payload.project, payload.text, payload.source)
    if any(type(value) is not str for value in values):
        raise NoteStateError('invalid_payload')
    try:
        encoded = tuple(value.encode('utf-8') for value in values)
    except UnicodeError as exc:
        raise NoteStateError('invalid_utf8') from exc
    if not payload.project:
        raise NoteStateError('invalid_payload')
    for name, value, maximum in zip(('project', 'text', 'source'), values, (300, 20000, 2000)):
        if value.isascii():
            # CRLF is the only multi-scalar extended grapheme in ASCII.
            if len(value) - value.count('\r\n') > maximum:
                raise NoteStateError('invalid_payload')
        elif len(value) > maximum:
            # Every grapheme contains at least one scalar, so <= maximum is safe.
            # The reverse is not true; never call this an invalid Swift payload.
            raise NoteStateError('unsupported_grapheme_boundary', name)
    return encoded + (struct.pack('>Q', raw),)


class ImmutableNoteEngine:
    """Internal digest injection permits collision tests, not hash negotiation."""
    def __init__(self, *, limits=Limits(), digest=None):
        self.limits = limits
        self._digest = (lambda raw: hashlib.sha256(raw).digest()) if digest is None else digest

    def content_bytes(self, payload: NotePayload) -> bytes:
        """Domain-separated tagged TLV hash framing, NOT state serialization."""
        values = _payload_bytes(payload)
        return CONTENT_DOMAIN + b''.join(
            bytes((tag,)) + struct.pack('>Q', len(value)) + value
            for tag, value in enumerate(values, 1))

    def content_key(self, payload: NotePayload) -> bytes:
        return _key(self._digest(self.content_bytes(payload)), 'invalid_hash_length')

    def normalize(self, state: ImmutableNoteStateV2) -> Result:
        return self.join((state,))

    def join(self, inputs: tuple[ImmutableNoteStateV2, ...]) -> Result:
        """Validate original hidden candidates before suppressing any body.

        Inputs are not independently normalized first: that could hide unequal
        available bodies behind tombstones. Retained bindings cannot recover an
        erased body or prove that a cryptographic collision was impossible.
        """
        self._validate_limits()
        _require_tuple(inputs)
        originals = tuple(self._inspect(state) for state in inputs)
        bindings, records, tombstones = {}, {}, set()
        for original_records, original_bindings, original_tombstones in originals:
            tombstones.update(original_tombstones)
            for id_, key in original_bindings.items():
                if id_ in bindings and bindings[id_] != key:
                    raise NoteStateError('immutable_conflict', id_)
                bindings[id_] = key
            for id_, record in original_records.items():
                if id_ in records and records[id_].payload != record.payload:
                    raise NoteStateError('immutable_conflict', id_)
                records[id_] = record
        payloads = {}
        for id_, record in records.items():
            key = bindings[id_]  # _inspect establishes a binding for every body.
            if key in payloads and payloads[key] != record.payload:
                raise NoteStateError('content_collision', key)
            payloads[key] = record.payload
        state = ImmutableNoteStateV2(
            records=tuple(records[id_] for id_ in sorted(records, key=_uuid_bytes) if id_ not in tombstones),
            bindings=tuple(NoteBinding(id_, bindings[id_]) for id_ in sorted(bindings, key=_uuid_bytes)),
            tombstones=tuple(sorted(tombstones, key=_uuid_bytes)))
        return Result(state, self._preflight(state))

    def _inspect(self, state):
        if type(state) is not ImmutableNoteStateV2:
            raise NoteStateError('invalid_state')
        if (type(state.format) is not str or state.format != 'veyra-immutable-notes-v2'
                or type(state.identity_scheme) is not str or state.identity_scheme != 'note-payload-tlv-v2'):
            raise NoteStateError('invalid_metadata')
        for collection in (state.records, state.bindings, state.tombstones):
            _require_tuple(collection)
        tombstones = set()
        for id_ in state.tombstones:
            _uuid_bytes(id_)
            if id_ in tombstones:
                raise NoteStateError('duplicate_tombstone', id_)
            tombstones.add(id_)
        bindings = {}
        for binding in state.bindings:
            if type(binding) is not NoteBinding:
                raise NoteStateError('invalid_binding')
            _uuid_bytes(binding.id)
            _key(binding.content_key)
            if binding.id in bindings:
                raise NoteStateError('duplicate_binding', binding.id)
            bindings[binding.id] = binding.content_key
        records, payloads = {}, {}
        for record in state.records:
            if type(record) is not NoteRecord:
                raise NoteStateError('invalid_record')
            _uuid_bytes(record.id)
            if record.id in records:
                raise NoteStateError('duplicate_record', record.id)
            records[record.id] = record
            key = self.content_key(record.payload)
            if record.id in bindings and bindings[record.id] != key:
                raise NoteStateError('immutable_conflict', record.id)
            bindings[record.id] = key
            if key in payloads and payloads[key] != record.payload:
                raise NoteStateError('content_collision', key)
            payloads[key] = record.payload
        for id_ in bindings:
            if id_ not in records and id_ not in tombstones:
                raise NoteStateError('orphan_binding', id_)
        # Inferred bindings and ALL original bodies count even if later deleted.
        original = ImmutableNoteStateV2(records=state.records,
            bindings=tuple(NoteBinding(id_, key) for id_, key in bindings.items()),
            tombstones=state.tombstones)
        self._preflight(original)
        return records, bindings, tombstones

    def _validate_limits(self):
        if type(self.limits) is not Limits:
            raise NoteStateError('invalid_limits')
        for field in fields(Limits):
            value = getattr(self.limits, field.name)
            if type(value) is not int or not 0 <= value <= INT64_MAX:
                raise NoteStateError('invalid_limits')
        for name, maximum in (
                ('maximum_notes', 10000), ('maximum_records', 30000), ('maximum_tombstones', 20000),
                ('maximum_document_bytes', 8 * 1024 * 1024), ('maximum_journal_bytes', 17 * 1024 * 1024)):
            if getattr(self.limits, name) > maximum:
                raise NoteStateError('invalid_limits')

    def _preflight(self, state):
        # Conservative reservations only, not actual encoded/encrypted sizes.
        amount = 512
        for count, rate in ((len(state.records), 256), (len(state.bindings), 160), (len(state.tombstones), 128)):
            amount = _checked_add(amount, _checked_multiply(count, rate))
        for record in state.records:
            for value in (record.payload.project, record.payload.text, record.payload.source):
                amount = _checked_add(amount, _checked_multiply(len(value.encode('utf-8')), 6))
        journal_amount = _checked_multiply(amount, 2)
        records = _checked_add(len(state.records), self.limits.other_records)
        tombstones = _checked_add(len(state.tombstones), self.limits.other_tombstones)
        document = _checked_add(amount, self.limits.other_document_bytes)
        journal = _checked_add(journal_amount, self.limits.other_journal_bytes)
        for value, maximum, code in (
                (len(state.records), self.limits.maximum_notes, 'notes'),
                (records, self.limits.maximum_records, 'records'),
                (tombstones, self.limits.maximum_tombstones, 'tombstones'),
                (document, self.limits.maximum_document_bytes, 'document_bytes'),
                (journal, self.limits.maximum_journal_bytes, 'journal_bytes')):
            if value > maximum:
                raise NoteStateError('capacity_' + code)
        return Usage(len(state.records), len(state.bindings), records, tombstones,
                     amount, journal_amount, document, journal)
