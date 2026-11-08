"""Explicitly owned paired files and retained rollback journals; never ACL repair."""
import os
from pathlib import Path
import sqlite3
import tempfile
import uuid
from .core import PlanError


def create_file(path):
    """Create a new empty file, refusing any preexisting object."""
    if os.name == 'nt':
        from .paired_windows import create_mutable_file
        return create_mutable_file(path)
    return os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)


def open_lock(path):
    if path.exists() or path.is_symlink():
        # The caller validates the state before and after opening. Never let an
        # existing-file open fall back to token-default creation on Windows.
        return os.open(path, os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_BINARY', 0))
    return create_file(path)


def temporary_file(directory):
    if os.name == 'nt':
        path = Path(directory) / ('.veyra-job-' + uuid.uuid4().hex)
        return create_file(path), str(path)
    return tempfile.mkstemp(prefix='.veyra-job-', dir=directory)


def _rollback_database(path):
    # WAL mode can create a default-owner shared-memory file while SQLite opens
    # the database. Reject it before opening SQLite, not after those side effects.
    with open(path, 'rb') as handle: header = handle.read(20)
    if header and (len(header) != 20 or header[:16] != b'SQLite format 3\x00' or header[18:20] != b'\x01\x01'):
        raise PlanError('Paired storage requires a rollback-journal database')


def connect(path, *, storage_check, timeout=2, isolation_level=None):
    """SQLite may reuse owned journals, but must not create token-default files.

    TRUNCATE preserves the journal object on commit/rollback. Precreate it with
    exact ownership, including after recovery removes an old hot journal. No
    existing object's owner, DACL or data is repaired by these helpers.
    """
    path = Path(path)
    storage_check(); _rollback_database(path)
    journal = Path(str(path) + '-journal')
    def ensure_journal():
        storage_check()
        if not journal.exists() and not journal.is_symlink(): os.close(create_file(journal))
        storage_check()
    ensure_journal()
    # mode=rw also prevents accidental SQLite token-default database creation.
    db = sqlite3.connect(path.as_uri() + '?mode=rw', uri=True, timeout=timeout, isolation_level=isolation_level)
    try:
        if db.execute('PRAGMA journal_mode=TRUNCATE').fetchone()[0] != 'truncate':
            raise PlanError('Paired rollback journal is unavailable')
        ensure_journal()
        return db
    except BaseException:
        db.close()
        raise
