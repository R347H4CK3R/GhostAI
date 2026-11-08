"""Manual, authenticated memory snapshots. No network and no task-log transfer."""
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import uuid

from .core import Memory

HEADER = b'VEYRA-MEMORY\x00\x01'
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_RECORDS = 10000
ITERATIONS = 600000
FIELDS = {'id', 'project', 'body', 'source', 'created'}


class SyncError(ValueError):
    """Invalid snapshot, credentials, or transfer request."""


def _crypto():
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
        from cryptography.hazmat.primitives import hashes
    except ImportError as exc:
        raise SyncError('Install companion/requirements-sync.txt for encrypted transfer') from exc
    return AESGCM, PBKDF2HMAC, hashes


def _key(passphrase, salt):
    if type(passphrase) is not str or not passphrase or len(passphrase.encode('utf-8')) > 4096:
        raise SyncError('Passphrase must be nonempty and at most 4096 UTF-8 bytes')
    _, pbkdf, hashes = _crypto()
    return pbkdf(algorithm=hashes.SHA256(), length=32, salt=salt,
                 iterations=ITERATIONS).derive(passphrase.encode('utf-8'))


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True,
                      allow_nan=False).encode('utf-8')


def validate_snapshot(snapshot):
    """Validate every record using the same credential policy as Memory.add."""
    if type(snapshot) is not dict or set(snapshot) != {'version', 'records'}:
        raise SyncError('Invalid snapshot schema')
    if type(snapshot['version']) is not int or snapshot['version'] != 1:
        raise SyncError('Unsupported snapshot version')
    rows = snapshot['records']
    if type(rows) is not list or len(rows) > MAX_RECORDS:
        raise SyncError('Invalid records or record limit exceeded')
    seen = set()
    decoded_bytes = 0
    staging = Memory(':memory:')
    try:
        for row in rows:
            if type(row) is not dict or set(row) != FIELDS:
                raise SyncError('Invalid memory schema')
            decoded_bytes += sum(len(value.encode('utf-8')) for value in row.values() if isinstance(value, str))
            if decoded_bytes + len(HEADER) + 44 > MAX_FILE_BYTES:
                raise SyncError('Decoded memory size limit exceeded')
            ident = row['id']
            if type(ident) is not str or not ident or len(ident.encode('utf-8')) > 128 or ident in seen:
                raise SyncError('Invalid or duplicate memory ID')
            seen.add(ident)
            created = row['created']
            if type(created) not in (int, float) or not math.isfinite(created) or not 0 <= created <= 253402300799:
                raise SyncError('Invalid memory date')
            try:
                staging.add(row['project'], row['body'], row['source'])
                # IDs also cross the boundary; apply credential policy to them.
                staging.add('validation', ident, 'snapshot')
            except (ValueError, UnicodeError) as exc:
                raise SyncError('Invalid memory text or possible credential rejected') from exc
    finally:
        staging.close()
    return rows


def export_snapshot(memory, path, passphrase, *, project=None, all_projects=False):
    """Create a new encrypted file; existing destinations are never overwritten."""
    if type(all_projects) is not bool or (project is None) == (not all_projects):
        raise SyncError('Choose exactly one project or explicit all_projects=True')
    if project is not None and (type(project) is not str or not project.strip()):
        raise SyncError('Project must be nonempty')
    sql = 'SELECT id, project, body, source, created FROM memories'
    args = ()
    if not all_projects:
        sql += ' WHERE project=?'
        args = (project,)
    sql += ' ORDER BY id LIMIT ?'
    rows, decoded_bytes = [], 0
    for row in memory.db.execute(sql, (*args, MAX_RECORDS + 1)):
        record = dict(row)
        decoded_bytes += sum(len(value.encode('utf-8')) for value in record.values() if isinstance(value, str))
        if decoded_bytes + len(HEADER) + 44 > MAX_FILE_BYTES:
            raise SyncError('Decoded memory size limit exceeded')
        rows.append(record)
    snapshot = {'version': 1, 'records': rows}
    validate_snapshot(snapshot)
    raw = _canonical(snapshot)
    if len(raw) + len(HEADER) + 16 + 12 + 16 > MAX_FILE_BYTES:
        raise SyncError('Snapshot exceeds encrypted file size limit')
    aes, _, _ = _crypto()
    salt, nonce = os.urandom(16), os.urandom(12)
    prefix = HEADER + salt + nonce
    encrypted = prefix + aes(_key(passphrase, salt)).encrypt(nonce, raw, prefix)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_BINARY', 0), 0o600)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(encrypted)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        Path(path).unlink(missing_ok=True)
        raise
    return len(rows)


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise SyncError('Duplicate JSON key')
        result[key] = value
    return result


def _read_snapshot(path, passphrase):
    # Reject symlinks on platforms without O_NOFOLLOW as well.
    if Path(path).is_symlink():
        raise SyncError('Snapshot must not be a symlink')
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) |
                 getattr(os, 'O_NONBLOCK', 0) | getattr(os, 'O_BINARY', 0))
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE_BYTES:
            raise SyncError('Snapshot must be a bounded regular file')
        data = handle.read(MAX_FILE_BYTES + 1)
    offset = len(HEADER)
    if len(data) > MAX_FILE_BYTES or len(data) < offset + 44 or not data.startswith(HEADER):
        raise SyncError('Invalid snapshot size or version header')
    salt, nonce = data[offset:offset + 16], data[offset + 16:offset + 28]
    prefix = data[:offset + 28]
    aes, _, _ = _crypto()
    key = _key(passphrase, salt)
    from cryptography.exceptions import InvalidTag
    try:
        raw = aes(key).decrypt(nonce, data[offset + 28:], prefix)
    except InvalidTag as exc:
        raise SyncError('Incorrect passphrase or damaged snapshot') from exc
    try:
        snapshot = json.loads(raw, object_pairs_hook=_pairs)
        return validate_snapshot(snapshot)
    except (ValueError, UnicodeError, RecursionError, OverflowError) as exc:
        raise SyncError('Invalid snapshot content') from exc


def import_snapshot(memory, path, passphrase):
    """Atomically merge verified records without deleting or overwriting any row."""
    rows = _read_snapshot(path, passphrase)
    report = {'added': 0, 'duplicates': 0, 'conflicts': []}
    savepoint = 'snapshot_' + uuid.uuid4().hex
    memory.db.execute('SAVEPOINT ' + savepoint)
    try:
        for row in sorted(rows, key=lambda item: item['id']):
            original = row['id']
            candidate = dict(row)
            counter = 0
            while True:
                existing = memory.db.execute('SELECT * FROM memories WHERE id=?', (candidate['id'],)).fetchone()
                if existing is None:
                    memory.db.execute('INSERT INTO memories VALUES (?,?,?,?,?)',
                                      tuple(candidate[key] for key in ('id', 'project', 'body', 'source', 'created')))
                    report['added'] += 1
                    break
                if dict(existing) == candidate:
                    report['duplicates'] += 1
                    break
                digest = hashlib.sha256(_canonical(row)).hexdigest()
                candidate['id'] = str(uuid.uuid5(uuid.NAMESPACE_URL, 'veyra-memory:' + digest + ':' + str(counter)))
                counter += 1
            if candidate['id'] != original:
                report['conflicts'].append({'original_id': original, 'imported_id': candidate['id']})
        memory.db.execute('RELEASE SAVEPOINT ' + savepoint)
    except BaseException:
        memory.db.execute('ROLLBACK TO SAVEPOINT ' + savepoint)
        memory.db.execute('RELEASE SAVEPOINT ' + savepoint)
        raise
    return report
