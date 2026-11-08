"""Bounded, offline operations. No model, network client, or shell executor."""
from contextlib import contextmanager
import hashlib
import json
import os
import re
from pathlib import Path
import sqlite3
import stat
import tempfile
import threading
import time
import uuid


class PlanError(ValueError):
    pass


def load_plan(raw):
    if len(raw.encode('utf-8')) > 1_048_576:
        raise PlanError('Plan exceeds 1 MiB')
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise PlanError('Duplicate JSON key')
            result[key] = value
        return result
    def constant(value):
        raise PlanError('Non-finite JSON number')
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)
    except (ValueError, RecursionError) as error:
        raise PlanError(str(error)) from error


class Memory:
    """Local plaintext SQLite store. Explicit entries only, separated by project."""
    def __init__(self, path, *, storage_check=None):
        self.storage_check = storage_check
        self._check_storage()
        self.db = sqlite3.connect(path)
        try:
            self._check_storage()
            self.db.row_factory = sqlite3.Row
            self.db.executescript('''
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY, project TEXT NOT NULL, body TEXT NOT NULL,
                    source TEXT NOT NULL, created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS tasks (
                    id TEXT PRIMARY KEY, status TEXT NOT NULL, steps INTEGER NOT NULL,
                    error TEXT, created REAL NOT NULL);
            ''')
            self._check_storage()
        except BaseException:
            self.db.close()
            raise

    def _check_storage(self):
        if self.storage_check: self.storage_check()

    @contextmanager
    def _transaction(self):
        self._check_storage()
        with self.db:
            yield
            self._check_storage()
        self._check_storage()

    def close(self):
        self.db.close()

    def add(self, project, body, source):
        for text in (project, body, source):
            if not isinstance(text, str) or not text.strip() or len(text.encode()) > 65536:
                raise ValueError('Memory requires nonempty project, body and source, each at most 64 KiB')
        credential = re.compile(r'gh[pousr]_|github_pat_|-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----|\b(?:password|api_key|access_token|secret)\s*[:=]', re.IGNORECASE)
        if any(credential.search(value) for value in (project, body, source)):
            raise ValueError('Possible credential rejected; do not store secrets in memory')
        ident = str(uuid.uuid4())
        with self._transaction():
            self.db.execute('INSERT INTO memories VALUES (?,?,?,?,?)', (ident, project, body, source, time.time()))
        return ident

    def search(self, project, query):
        self._check_storage()
        return [dict(row) for row in self.db.execute(
            'SELECT * FROM memories WHERE project=? AND instr(lower(body),lower(?))>0 ORDER BY created DESC LIMIT 100',
            (project, query))]

    def delete(self, ident):
        with self._transaction():
            return self.db.execute('DELETE FROM memories WHERE id=?', (ident,)).rowcount > 0

    def audit(self, ident, status, steps, error):
        with self._transaction():
            self.db.execute('INSERT OR REPLACE INTO tasks VALUES (?,?,?,?,?)',
                            (ident, status, steps, error, time.time()))

    def tasks(self):
        self._check_storage()
        return [dict(row) for row in self.db.execute('SELECT * FROM tasks ORDER BY created DESC LIMIT 100')]


DEFAULTS = {'max_steps': 32, 'max_bytes': 1_048_576, 'max_entries': 1000, 'max_seconds': 30}
CEILINGS = {'max_steps': 100, 'max_bytes': 8_388_608, 'max_entries': 10000, 'max_seconds': 120}
TOOLS = {'list_files', 'read_file', 'validate_json', 'sha256', 'write_draft'}


def validate(plan):
    if type(plan) is not dict or set(plan) != {'version', 'steps', 'write_paths', 'budgets'}:
        raise PlanError('Plan requires exactly version, steps, write_paths, budgets')
    if type(plan['version']) is not int or plan['version'] != 1:
        raise PlanError('Unsupported plan version')
    budgets = plan['budgets']
    if type(budgets) is not dict or set(budgets) - set(DEFAULTS):
        raise PlanError('Unknown budget')
    for key, value in budgets.items():
        if type(value) is not int or not 1 <= value <= CEILINGS[key]:
            raise PlanError('Invalid budget: ' + key)
    limits = dict(DEFAULTS, **budgets)
    if type(plan['steps']) is not list or len(plan['steps']) > limits['max_steps']:
        raise PlanError('Step limit exceeded or invalid steps')
    if type(plan['write_paths']) is not list or len(plan['write_paths']) > 100 or any(type(p) is not str for p in plan['write_paths']):
        raise PlanError('Invalid write scope')
    for step in plan['steps']:
        if type(step) is not dict or type(step.get('tool')) is not str or step['tool'] not in TOOLS:
            raise PlanError('Unknown tool')
        keys = {'tool', 'path', 'content'} if step['tool'] == 'write_draft' else {'tool', 'path'}
        if set(step) != keys or any(type(value) is not str for value in step.values()):
            raise PlanError('Invalid tool arguments')
    return limits


def check_links(path):
    for part in [path, *path.parents]:
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
            raise PlanError('Symlink or reparse point rejected')


class Runner:
    def __init__(self, workspace, memory, allow_writes=False, cancel=None):
        self.root = Path(os.path.abspath(workspace))
        check_links(self.root)
        if not self.root.is_dir():
            raise PlanError('Workspace must be an existing directory')
        self.memory = memory
        self.allow_writes = allow_writes
        self.cancel = cancel if cancel is not None else threading.Event()

    def path(self, name, write=False):
        if not name or '\\' in name or ':' in name or name.startswith('/'):
            raise PlanError('Invalid relative path')
        parts = name.split('/')
        reserved = {'CON', 'PRN', 'AUX', 'NUL', 'CONIN$', 'CONOUT$'} | {prefix + digit for prefix in ('COM', 'LPT') for digit in '123456789¹²³'}
        if any(p.split('.')[0].upper() in reserved or any(ord(c) < 32 or c in '<>\"|?*' for c in p) for p in parts):
            raise PlanError('Reserved filename rejected')
        if any(p in ('', '..') or (p == '.' and name != '.') or p.endswith((' ', '.')) and p != '.' for p in parts):
            raise PlanError('Noncanonical path rejected')
        path = self.root.joinpath(*parts)
        check_links(path.parent if write and not path.exists() else path)
        if write and len(parts) != 1:
            raise PlanError('Drafts must be direct children of workspace')
        return path

    def checkpoint(self):
        if self.cancel.is_set():
            raise InterruptedError('Cancelled')
        if time.monotonic() - self.started > self.limits['max_seconds']:
            raise PlanError('Time budget exceeded')

    def consume(self, count):
        self.used += count
        if self.used > self.limits['max_bytes']:
            raise PlanError('Byte budget exceeded')
        self.checkpoint()

    def read(self, path):
        flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
        fd = os.open(path, flags)
        with os.fdopen(fd, 'rb') as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                raise PlanError('Only regular, non-hardlinked files allowed')
            data = handle.read(self.limits['max_bytes'] - self.used + 1)
        self.consume(len(data))
        return data

    def execute(self, step, scope):
        tool, name = step['tool'], step['path']
        path = self.path(name, write=tool == 'write_draft')
        if tool == 'list_files':
            names = []
            with os.scandir(path) as entries:
                for entry in entries:
                    self.checkpoint()
                    if len(names) >= self.limits['max_entries']:
                        raise PlanError('Directory entry budget exceeded')
                    check_links(Path(entry.path))
                    self.consume(len(entry.name.encode('utf-8')))
                    names.append(entry.name)
            return sorted(names)
        if tool == 'write_draft':
            if not self.allow_writes or name not in scope:
                raise PlanError('Write requires --allow-writes and exact write_paths authorization')
            if path.exists():
                raise PlanError('Draft already exists; overwrites are forbidden')
            data = step['content'].encode('utf-8')
            self.consume(len(data))
            fd, temporary = tempfile.mkstemp(prefix='.veyra-', dir=self.root)
            try:
                with os.fdopen(fd, 'wb') as handle:
                    handle.write(data)
                    handle.flush()
                    os.fsync(handle.fileno())
                self.checkpoint()
                check_links(self.root)
                # Atomic create-if-absent: never overwrite even if destination appeared.
                os.link(temporary, path)
            finally:
                os.unlink(temporary)
            return {'created': name, 'bytes': len(data)}
        data = self.read(path)
        if tool == 'sha256':
            return hashlib.sha256(data).hexdigest()
        text = data.decode('utf-8')
        if tool == 'validate_json':
            load_plan(text)
            return {'valid': True}
        return text

    def run(self, plan):
        ident = str(uuid.uuid4())
        results = []
        self.started, self.used = time.monotonic(), 0
        self.memory.audit(ident, 'running', 0, None)
        status, error = 'completed', None
        try:
            self.limits = validate(plan)
            # Preflight all paths and write permissions before any side effects.
            for step in plan['steps']:
                self.path(step['path'], write=step['tool'] == 'write_draft')
                if step['tool'] == 'write_draft' and (not self.allow_writes or step['path'] not in plan['write_paths']):
                    raise PlanError('Write not authorized')
            for step in plan['steps']:
                self.checkpoint()
                results.append(self.execute(step, plan['write_paths']))
                self.memory.audit(ident, 'running', len(results), None)
        except (InterruptedError, KeyboardInterrupt):
            status, error = 'cancelled', 'Cancelled'
        except (OSError, ValueError, RecursionError) as exc:
            status, error = 'failed', str(exc)
        self.memory.audit(ident, status, len(results), error)
        return {'id': ident, 'status': status, 'results': results, 'error': error}
