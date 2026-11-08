"""Verify the synthetic Swift XCTest attachment with the real desktop importer.

Usage: python Tests/verify_mobile_transfer.py test-screenshots
Missing fixtures fail. --self-test checks the verifier/reference vectors only;
it is explicitly not evidence that Swift has executed.
"""
import argparse
import base64
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from companion.core import Memory
from companion import sync


# Public, synthetic test data only. These are not user credentials or memory.
PASSPHRASE = 'correct horse café fixture'
ATTACHMENT_NAME = 'swift-desktop-transfer.veyra'
EXPECTED = {
    'id': '12345678-1234-5678-1234-567812345678',
    'project': 'fixture/mobile',
    'body': 'Café offline memory',
    'source': 'fixture',
    'created': 1700000000.0,
}


def verify_fixture(path):
    memory = Memory(':memory:')
    try:
        report = sync.import_snapshot(memory, path, PASSPHRASE)
        if report != {'added': 1, 'duplicates': 0, 'conflicts': []}:
            raise ValueError('Unexpected import report for synthetic Swift fixture')
        if memory.search('fixture/mobile', '') != [EXPECTED]:
            raise ValueError('Swift fixture did not preserve the expected note fields')
        if memory.db.execute('SELECT count(*) FROM memories').fetchone()[0] != 1:
            raise ValueError('Unexpected extra records, including possible chat content')
        if memory.tasks():
            raise ValueError('Task records must never be transferred')
        repeated = sync.import_snapshot(memory, path, PASSPHRASE)
        if repeated != {'added': 0, 'duplicates': 1, 'conflicts': []}:
            raise ValueError('Repeated import duplicated or changed the note')
    finally:
        memory.close()

    encrypted = path.read_bytes()
    with tempfile.TemporaryDirectory() as directory:
        corrupt = Path(directory) / 'corrupt.veyra'
        for index in (0, 13, 14, 30, 42, len(encrypted) - 1):
            data = bytearray(encrypted)
            data[index] ^= 1
            corrupt.write_bytes(data)
            _expect_rejection(corrupt, PASSPHRASE)
        _expect_rejection(path, 'deliberately wrong synthetic passphrase')


def _expect_rejection(path, passphrase):
    memory = Memory(':memory:')
    try:
        try:
            sync.import_snapshot(memory, path, passphrase)
        except sync.SyncError:
            pass
        else:
            raise ValueError('Wrong passphrase or corrupted synthetic fixture was accepted')
        if memory.db.execute('SELECT count(*) FROM memories').fetchone()[0] != 0:
            raise ValueError('Failed authentication changed the destination memory')
    finally:
        memory.close()


def find_fixtures(root):
    if not root.exists():
        raise ValueError(f'Missing XCTest attachment export: {root}')
    # xcresulttool may replace the attachment name with an opaque exported file
    # name. Inspect bounded regular files by their unencrypted format header,
    # then require the exact synthetic payload in verify_fixture.
    candidates = [root] if root.is_file() else sorted(root.rglob('*'))
    fixtures = []
    for path in candidates:
        if path.is_symlink() or not path.is_file():
            continue
        if not 58 <= path.stat().st_size <= sync.MAX_FILE_BYTES:
            continue
        with path.open('rb') as handle:
            if handle.read(len(sync.HEADER)) == sync.HEADER:
                fixtures.append(path)
    if not fixtures:
        raise ValueError(f'Missing {ATTACHMENT_NAME} XCTest attachment; interoperability was NOT verified')
    return fixtures


def self_test():
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    import json

    source = Path(__file__).with_name('EncryptedTransferTests.swift').read_text()
    fixtures = {}
    for name in ('mobileFixture', 'desktopFixture'):
        match = re.search(r'private let ' + name + r' = "([A-Za-z0-9+/=]+)"', source)
        if not match:
            raise ValueError(f'Missing committed reference vector: {name}')
        fixtures[name] = base64.b64decode(match[1], validate=True)

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        try:
            find_fixtures(root)
        except ValueError:
            pass
        else:
            raise ValueError('The verifier incorrectly allowed a missing fixture')
        desktop = root / ATTACHMENT_NAME
        desktop.write_bytes(fixtures['desktopFixture'])
        if find_fixtures(root) != [desktop]:
            raise ValueError('Synthetic fixture discovery failed')
        verify_fixture(desktop)

    encrypted = fixtures['mobileFixture']
    if encrypted[:14] != b'VEYRA-MOBILE\x00\x01':
        raise ValueError('Wrong mobile reference header')
    key = PBKDF2HMAC(algorithm=hashes.SHA256(), length=32, salt=encrypted[14:30],
                     iterations=600000).derive(PASSPHRASE.encode('utf-8'))
    payload = json.loads(AESGCM(key).decrypt(encrypted[30:42], encrypted[42:], encrypted[:42]))
    expected_mobile = {'version': 1, 'notes': [{
        'id': EXPECTED['id'], 'project': EXPECTED['project'], 'text': EXPECTED['body'],
        'source': EXPECTED['source'], 'savedAt': 721692800,
    }], 'chats': []}
    if payload != expected_mobile:
        raise ValueError('Unexpected mobile reference payload')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('attachments', type=Path, nargs='?')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
            print('PASS: verifier and Python reference vectors; Swift execution was not checked.')
        if args.attachments is not None:
            paths = find_fixtures(args.attachments)
            for path in paths:
                verify_fixture(path)
            print(f'PASS: {len(paths)} Swift desktop fixture(s), schema, Unicode, IDs, Unix timestamps, notes-only content, idempotence, wrong-passphrase and tamper rejection.')
        elif not args.self_test:
            parser.error('supply the xcresult attachment export directory or --self-test')
    except (OSError, ValueError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
