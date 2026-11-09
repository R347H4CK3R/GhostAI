"""Unused bounded chat-state reference for a future v2, not a vault/wire codec.

No production caller, I/O, credentials, v1 identity changes, imports, migration,
mirrors, or writer authorization. Payload strings are exact UTF-8, keys/date bits
are immutable bytes, and UUID strings use lowercase hyphenated spelling. ACI is
only claimed for compatible normalized states whose intermediate joins fit the
same limits. All operations return new values or fail without changing inputs.
"""
from __future__ import annotations

from dataclasses import dataclass, fields, replace
import hashlib
import math
import re
import struct
import uuid

UINT64_MAX = (1 << 64) - 1
CONTENT_DOMAIN = b'Veyra chat content v2\0'
IDENTITY_DOMAIN = b'Veyra chat variant identity v2\0'
_UUID = re.compile(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\Z')


class ChatStateError(ValueError):
    """Structured failure; no partial state is returned."""
    def __init__(self, code: str, detail=None):
        self.code, self.detail = code, detail
        super().__init__(code if detail is None else f'{code}: {detail}')


@dataclass(frozen=True)
class ChatPayload:
    project: str
    role: str
    text: str


def _uuid_bytes(value):
    if type(value) is not str or not _UUID.fullmatch(value):
        raise ChatStateError('invalid_uuid')
    return uuid.UUID(value).bytes


def _fixed_bytes(value, size, code):
    if type(value) is not bytes or len(value) != size:
        raise ChatStateError(code)
    return value


def _uint64(value):
    if type(value) is not int or not 0 <= value <= UINT64_MAX:
        raise ChatStateError('invalid_counter')
    return value


def parse_counter_v2(value: str) -> int:
    """Canonical UInt64 primitive only; not a wire-state decoder."""
    if (type(value) is not str or not re.fullmatch(r'0|[1-9][0-9]{0,19}', value)):
        raise ChatStateError('invalid_counter')
    return _uint64(int(value))


def _payload_bytes(payload):
    if type(payload) is not ChatPayload:
        raise ChatStateError('invalid_payload')
    values = (payload.project, payload.role, payload.text)
    if any(type(value) is not str for value in values) or payload.role not in ('user', 'assistant'):
        raise ChatStateError('invalid_payload')
    try:
        return tuple(value.encode('utf-8') for value in values)
    except UnicodeError as exc:
        raise ChatStateError('invalid_utf8') from exc


def content_bytes_v2(payload: ChatPayload) -> bytes:
    fields = _payload_bytes(payload)
    return CONTENT_DOMAIN + b''.join(struct.pack('>Q', _uint64(len(field))) + field for field in fields)


def _date_value(raw):
    _fixed_bytes(raw, 8, 'invalid_date')
    value = struct.unpack('>d', raw)[0]
    # Direct Foundation-reference range. Never add/subtract the Unix offset.
    if not math.isfinite(value) or not -978307200 <= value <= 252423993599:
        raise ChatStateError('invalid_date')
    return value


def date_min_bits(a: bytes, b: bytes) -> bytes:
    av, bv = _date_value(a), _date_value(b)
    return a if (av, a) <= (bv, b) else b


@dataclass(frozen=True)
class OrderKey:
    counter: int
    origin_id: str
    batch_id: str
    sequence: int


@dataclass(frozen=True)
class ChatVariant:
    content_key: bytes
    payload: ChatPayload
    earliest_date_bits: bytes


@dataclass(frozen=True)
class ChatFamily:
    family_id: str
    anchor_content_key: bytes
    order_key: OrderKey
    variants: tuple[ChatVariant, ...]


@dataclass(frozen=True)
class ChatReference:
    family_id: str
    content_key: bytes
    projected_id: str


@dataclass(frozen=True)
class ChatStateV2:
    format: str = 'veyra-chat-families-v2'
    identity_scheme: str = 'chat-content-v2'
    order_clock: int = 0
    families: tuple[ChatFamily, ...] = ()
    family_deletes: tuple[str, ...] = ()
    variant_deletes: tuple[ChatReference, ...] = ()
    chat_tombstones: tuple[str, ...] = ()


@dataclass(frozen=True)
class Limits:
    maximum_live_variants: int = 10_000
    maximum_records: int = 30_000
    maximum_families: int = 30_000
    maximum_tombstones: int = 20_000
    maximum_document_bytes: int = 8 * 1024 * 1024
    maximum_journal_bytes: int = 17 * 1024 * 1024
    other_records: int = 0
    other_tombstones: int = 0
    other_document_bytes: int = 0
    other_journal_bytes: int = 0


@dataclass(frozen=True)
class Usage:
    live_variants: int
    retained_roots: int
    tombstones: int
    document_bytes: int
    journal_bytes: int


@dataclass(frozen=True)
class ValidatedChatStateV2:
    state: ChatStateV2
    usage: Usage
    references: tuple[ChatReference, ...]


@dataclass(frozen=True)
class ChatProjectionRow:
    reference: ChatReference
    payload: ChatPayload
    earliest_date_bits: bytes


@dataclass(frozen=True)
class ChatMutationResult:
    state: ValidatedChatStateV2
    added_ids: frozenset[str]
    added_variant_deletes: frozenset[ChatReference]
    added_family_deletes: frozenset[str]
    added_tombstones: frozenset[str]


def _order_tuple(value):
    if type(value) is not OrderKey:
        raise ChatStateError('invalid_order_key')
    return (_uint64(value.counter), _uuid_bytes(value.origin_id),
            _uuid_bytes(value.batch_id), _uint64(value.sequence))


def _reference_tuple(value):
    if type(value) is not ChatReference:
        raise ChatStateError('invalid_reference')
    return (_uuid_bytes(value.family_id), _fixed_bytes(value.content_key, 32, 'invalid_key'),
            _uuid_bytes(value.projected_id))


def _require_tuple(value):
    if type(value) is not tuple:
        raise ChatStateError('invalid_collection')


class ChatEngine:
    """Hash dependency injection exercises collision failures, not identity salts."""
    def __init__(self, *, limits=Limits(), digest=None):
        self.limits = limits
        self._digest = digest or (lambda raw: hashlib.sha256(raw).digest())

    def _hash(self, raw):
        return _fixed_bytes(self._digest(raw), 32, 'invalid_hash_length')

    def content_key(self, payload: ChatPayload) -> bytes:
        return self._hash(content_bytes_v2(payload))

    def variant_id(self, family_id: str, anchor_key: bytes, key: bytes) -> str:
        root = _uuid_bytes(family_id)
        _fixed_bytes(anchor_key, 32, 'invalid_key')
        _fixed_bytes(key, 32, 'invalid_key')
        if key == anchor_key:
            return family_id
        raw = bytearray(self._hash(IDENTITY_DOMAIN + root + key)[:16])
        raw[6] = (raw[6] & 15) | 128
        raw[8] = (raw[8] & 63) | 128
        return str(uuid.UUID(bytes=bytes(raw)))


    def _validate_limits(self):
        if type(self.limits) is not Limits or any(
                type(getattr(self.limits, f.name)) is not int or getattr(self.limits, f.name) < 0
                for f in fields(Limits)):
            raise ChatStateError('invalid_limits')

    def _reference(self, family, key):
        return ChatReference(family.family_id, key,
                             self.variant_id(family.family_id, family.anchor_content_key, key))

    def validate(self, state: ChatStateV2) -> ValidatedChatStateV2:
        """Check every supplied fact, then normalize typed deletions atomically.

        Tuples rather than mutable maps preserve immutability and expose duplicate
        keys for rejection. Output tuples are sorted in canonical byte order.
        Outer note markers are not accepted or rewritten here; the caller reserves
        their count/bytes in Limits and must preserve their original strings.
        """
        self._validate_limits()
        if type(state) is not ChatStateV2:
            raise ChatStateError('invalid_state')
        if (type(state.format) is not str or state.format != 'veyra-chat-families-v2'
                or type(state.identity_scheme) is not str or state.identity_scheme != 'chat-content-v2'):
            raise ChatStateError('unsupported_epoch')
        clock = _uint64(state.order_clock)
        for collection in (state.families, state.family_deletes, state.variant_deletes, state.chat_tombstones):
            _require_tuple(collection)
        families = {}
        for family in state.families:
            if type(family) is not ChatFamily:
                raise ChatStateError('invalid_family')
            _uuid_bytes(family.family_id)
            _fixed_bytes(family.anchor_content_key, 32, 'invalid_key')
            _order_tuple(family.order_key)
            _require_tuple(family.variants)
            if family.family_id in families:
                raise ChatStateError('duplicate_family', family.family_id)
            families[family.family_id] = family
            clock = max(clock, family.order_key.counter)
        for value in state.family_deletes + state.chat_tombstones:
            _uuid_bytes(value)
        for selector in state.variant_deletes:
            _reference_tuple(selector)
        family_deletes, tombstones, selectors = set(state.family_deletes), set(state.chat_tombstones), set(state.variant_deletes)
        if len(family_deletes) != len(state.family_deletes) or len(tombstones) != len(state.chat_tombstones):
            raise ChatStateError('duplicate_marker')
        if len(selectors) != len(state.variant_deletes):
            raise ChatStateError('duplicate_selector')
        roots = set(families) | family_deletes
        owners, payloads = {}, {}

        def register(reference):
            family = families.get(reference.family_id)
            if family is None:
                raise ChatStateError('unknown_family', reference.family_id)
            if reference != self._reference(family, reference.content_key):
                raise ChatStateError('incorrect_projected_id', reference.projected_id)
            is_anchor = (reference.projected_id == family.family_id
                         and reference.content_key == family.anchor_content_key)
            if reference.projected_id in roots and not is_anchor:
                raise ChatStateError('identifier_collision', reference.projected_id)
            previous = owners.get(reference.projected_id)
            if previous is not None and previous != reference:
                raise ChatStateError('identifier_collision', reference.projected_id)
            owners[reference.projected_id] = reference

        for selector in selectors:
            register(selector)
        if tombstones != family_deletes | {ref.projected_id for ref in selectors}:
            raise ChatStateError('unexplained_or_missing_tombstone')
        # Validate all bodies before any deletion can hide a collision or bad fact.
        for family in state.families:
            keys = set()
            for variant in family.variants:
                if type(variant) is not ChatVariant:
                    raise ChatStateError('invalid_variant')
                key = _fixed_bytes(variant.content_key, 32, 'invalid_key')
                if key in keys:
                    raise ChatStateError('duplicate_variant', family.family_id)
                keys.add(key)
                _date_value(variant.earliest_date_bits)
                if self.content_key(variant.payload) != key:
                    raise ChatStateError('payload_key_mismatch', key.hex())
                if key in payloads and payloads[key] != variant.payload:
                    raise ChatStateError('content_collision', key.hex())
                payloads[key] = variant.payload
                register(self._reference(family, key))
            if (family.anchor_content_key not in keys and family.family_id not in family_deletes
                    and self._reference(family, family.anchor_content_key) not in selectors):
                raise ChatStateError('missing_anchor', family.family_id)
        output = []
        for family in state.families:
            remaining = []
            for variant in family.variants:
                ref = self._reference(family, variant.content_key)
                if family.family_id in family_deletes:
                    selectors.add(ref)
                    tombstones.add(ref.projected_id)
                if ref not in selectors:
                    remaining.append(variant)
            output.append(replace(family, variants=tuple(sorted(remaining, key=lambda v: v.content_key))))
        normalized = ChatStateV2(order_clock=clock,
            families=tuple(sorted(output, key=lambda f: _uuid_bytes(f.family_id))),
            family_deletes=tuple(sorted(family_deletes, key=_uuid_bytes)),
            variant_deletes=tuple(sorted(selectors, key=_reference_tuple)),
            chat_tombstones=tuple(sorted(tombstones, key=_uuid_bytes)))
        return ValidatedChatStateV2(normalized, self._preflight(normalized),
            tuple(self._reference(f, v.content_key) for f in normalized.families for v in f.variants))

    def _preflight(self, state):
        """Conservative chat-only JSON accounting, NOT a serializer/wire proof.

        Allowances include keys, punctuation, UUID/hash/date forms and 20-digit
        counters; six bytes per UTF-8 byte cover escaping. The journal allowance
        assumes two chat-state copies. Full remote/journal/SavedState framing and
        actual serialized sizes MUST be checked again by a future outer codec.
        """
        live = sum(len(f.variants) for f in state.families)
        roots = len({f.family_id for f in state.families} | set(state.family_deletes))
        size = 512 + 384 * len(state.families)
        size += sum(256 + 6 * sum(map(len, _payload_bytes(v.payload)))
                    for f in state.families for v in f.variants)
        size += 192 * len(state.variant_deletes) + 40 * (len(state.family_deletes) + len(state.chat_tombstones))
        limits = self.limits
        markers = len(state.chat_tombstones) + limits.other_tombstones
        document, journal = size + limits.other_document_bytes, 2 * size + limits.other_journal_bytes
        checks = ((live, limits.maximum_live_variants, 'live_variants'),
                  (live + limits.other_records, limits.maximum_records, 'records'),
                  (roots, limits.maximum_families, 'families'),
                  (markers, limits.maximum_tombstones, 'tombstones'),
                  (document, limits.maximum_document_bytes, 'document_bytes'),
                  (journal, limits.maximum_journal_bytes, 'journal_bytes'))
        for actual, maximum, name in checks:
            if actual > maximum:
                raise ChatStateError('capacity_' + name, {'required': actual, 'maximum': maximum})
        return Usage(live, roots, markers, document, journal)

    def _validated(self, value):
        # Python wrappers are constructible; never treat one as an authority token.
        if type(value) is not ValidatedChatStateV2:
            raise ChatStateError('invalid_validated_state')
        return self.validate(value.state)

    def join(self, a: ValidatedChatStateV2, b: ValidatedChatStateV2) -> ValidatedChatStateV2:
        left, right = self._validated(a).state, self._validated(b).state
        combined = {f.family_id: f for f in left.families}
        for family in right.families:
            old = combined.get(family.family_id)
            if old is not None and old.anchor_content_key != family.anchor_content_key:
                raise ChatStateError('anchor_conflict', family.family_id)
        for family in right.families:
            old = combined.get(family.family_id)
            if old is None:
                combined[family.family_id] = family
                continue
            variants = {v.content_key: v for v in old.variants}
            for variant in family.variants:
                existing = variants.get(variant.content_key)
                if existing is not None:
                    if existing.payload != variant.payload:
                        raise ChatStateError('content_collision', variant.content_key.hex())
                    variant = replace(variant, earliest_date_bits=date_min_bits(
                        existing.earliest_date_bits, variant.earliest_date_bits))
                variants[variant.content_key] = variant
            combined[family.family_id] = replace(family,
                order_key=min(old.order_key, family.order_key, key=_order_tuple), variants=tuple(variants.values()))
        return self.validate(ChatStateV2(order_clock=max(left.order_clock, right.order_clock),
            families=tuple(combined.values()),
            family_deletes=tuple(set(left.family_deletes) | set(right.family_deletes)),
            variant_deletes=tuple(set(left.variant_deletes) | set(right.variant_deletes)),
            chat_tombstones=tuple(set(left.chat_tombstones) | set(right.chat_tombstones))))

    def _project(self, state):
        rows = []
        for family in sorted(state.families, key=lambda f: (_order_tuple(f.order_key), _uuid_bytes(f.family_id))):
            for variant in sorted(family.variants, key=lambda v: (v.content_key != family.anchor_content_key, v.content_key)):
                rows.append(ChatProjectionRow(self._reference(family, variant.content_key), variant.payload,
                                              variant.earliest_date_bits))
        return tuple(rows)

    def project(self, value: ValidatedChatStateV2) -> tuple[ChatProjectionRow, ...]:
        """Presentation only; rendered order must never generate new ordering facts."""
        checked = self._validated(value)
        # Cached immutable references bind this projection to its validation hash
        # context. Another injected engine must not silently rename live rows.
        if value.references != checked.references:
            raise ChatStateError('validation_context_mismatch')
        return self._project(checked.state)

    def new_order_batch(self, clock: int, origin: str, persisted_batch: str, count: int) -> tuple[OrderKey, ...]:
        self._validate_limits()
        _uint64(clock); _uuid_bytes(origin); _uuid_bytes(persisted_batch)
        if type(count) is not int or not 0 < count <= min(self.limits.maximum_live_variants, UINT64_MAX):
            raise ChatStateError('capacity_order_batch')
        if clock == UINT64_MAX:
            raise ChatStateError('capacity_order_clock')
        return tuple(OrderKey(clock + 1, origin, persisted_batch, i) for i in range(count))

    def _mutation(self, before, after):
        old, new = before.state, after.state
        old_ids = {r.reference.projected_id for r in self._project(old)}
        new_ids = {r.reference.projected_id for r in self._project(new)}
        return ChatMutationResult(after, frozenset(new_ids - old_ids),
            frozenset(set(new.variant_deletes) - set(old.variant_deletes)),
            frozenset(set(new.family_deletes) - set(old.family_deletes)),
            frozenset(set(new.chat_tombstones) - set(old.chat_tombstones)))

    def observe(self, value, family_id, payload, original_date_bits):
        before = self._validated(value)
        _uuid_bytes(family_id); _date_value(original_date_bits)
        family = next((f for f in before.state.families if f.family_id == family_id), None)
        if family is None:
            raise ChatStateError('unknown_family', family_id)
        key = self.content_key(payload)
        variants = {v.content_key: v for v in family.variants}
        previous = variants.get(key)
        if previous is not None:
            if previous.payload != payload:
                raise ChatStateError('content_collision', key.hex())
            original_date_bits = date_min_bits(previous.earliest_date_bits, original_date_bits)
        variants[key] = ChatVariant(key, payload, original_date_bits)
        changed = replace(family, variants=tuple(variants.values()))
        after = self.validate(replace(before.state,
            families=tuple(changed if f.family_id == family_id else f for f in before.state.families)))
        return self._mutation(before, after)

    def delete_variants(self, value, references: frozenset[ChatReference]):
        before = self._validated(value)
        if type(references) is not frozenset:
            raise ChatStateError('invalid_collection')
        known = {r.reference for r in self._project(before.state)} | set(before.state.variant_deletes)
        for ref in references:
            _reference_tuple(ref)
            if ref not in known:
                raise ChatStateError('unknown_reference', ref)
        after = self.validate(replace(before.state,
            variant_deletes=tuple(set(before.state.variant_deletes) | references),
            chat_tombstones=tuple(set(before.state.chat_tombstones) | {r.projected_id for r in references})))
        return self._mutation(before, after)

    def delete_families(self, value, family_ids: frozenset[str]):
        before = self._validated(value)
        if type(family_ids) is not frozenset:
            raise ChatStateError('invalid_collection')
        known = {f.family_id for f in before.state.families} | set(before.state.family_deletes)
        for root in family_ids:
            _uuid_bytes(root)
            if root not in known:
                raise ChatStateError('unknown_family', root)
        after = self.validate(replace(before.state,
            family_deletes=tuple(set(before.state.family_deletes) | family_ids),
            chat_tombstones=tuple(set(before.state.chat_tombstones) | family_ids)))
        return self._mutation(before, after)


def content_key_v2(payload: ChatPayload) -> bytes:
    return ChatEngine().content_key(payload)


def variant_id_v2(family_id: str, anchor_key: bytes, key: bytes) -> str:
    return ChatEngine().variant_id(family_id, anchor_key, key)
