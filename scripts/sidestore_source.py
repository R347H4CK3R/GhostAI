"""Pure, fail-closed AltStore Classic source rendering for the unsigned iOS app."""
import hashlib
import json
import re
import struct
import stat
import zipfile
from datetime import datetime

from publish_ios_update import ASSET, REPOSITORY, validate_ipa

SOURCE_BRANCH = 'sidestore-source'
SOURCE_URL = f'https://raw.githubusercontent.com/{REPOSITORY}/{SOURCE_BRANCH}/source.json'
IDENTIFIER = 'dev.asterionveyra.source'
BUNDLE = 'dev.asterionveyra.assistant'
APP = 'Payload/AsterionVeyra.app/'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def release_url(build):
    return f'https://github.com/{REPOSITORY}/releases/download/ios-build-{build}/{ASSET}'


def check_unsigned_binary(binary):
    # Current CI produces a thin, unsigned ARM64 MH_EXECUTE, not a fat binary.
    if len(binary) < 32:
        raise ValueError('Missing Mach-O executable')
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from('<8I', binary)
    if (magic != 0xfeedfacf or cpu != 0x100000c or kind != 2
            or size > len(binary) - 32 or count > size // 8):
        raise ValueError('Unsupported or malformed unsigned executable')
    offset = 32
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError('Truncated Mach-O load command')
        command, length = struct.unpack_from('<2I', binary, offset)
        if length < 8 or length % 8 or offset + length > 32 + size:
            raise ValueError('Malformed Mach-O load command')
        if command == 0x1d:  # LC_CODE_SIGNATURE may contain unadvertised entitlements.
            raise ValueError('Signed executable needs explicit entitlement extraction')
        offset += length
    if offset != 32 + size:
        raise ValueError('Inconsistent Mach-O command size')


def render_source(path, build, commit, date):
    if type(build) is not int or build <= 0 or not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('Invalid source provenance')
    if not isinstance(date, str) or not date.endswith('Z'):
        raise ValueError('Expected UTC release timestamp')
    datetime.fromisoformat(date.replace('Z', '+00:00'))
    info = validate_ipa(path, build)
    version = info['CFBundleShortVersionString']
    minimum = info.get('MinimumOSVersion', '')
    if (not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', version)
            or not isinstance(minimum, str)
            or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', minimum)
            or int(minimum.split('.')[0]) < 26):
        raise ValueError('Invalid version or unsupported minimum iOS')
    executable = info.get('CFBundleExecutable', '')
    if not isinstance(executable, str) or not re.fullmatch('[A-Za-z0-9_-]+', executable):
        raise ValueError('Invalid executable name')
    privacy = {key: value for key, value in info.items() if 'UsageDescription' in key}
    if any(not isinstance(value, str) or not value.strip() for value in privacy.values()):
        raise ValueError('Privacy descriptions must be nonempty strings')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        for entry in archive.infolist():
            parts = entry.filename.rstrip('/').split('/')
            mode = stat.S_IFMT(entry.external_attr >> 16)
            if (any(part in ('', '.', '..') for part in parts)
                    or '\\' in entry.filename or '\x00' in entry.orig_filename
                    or mode not in (0, stat.S_IFREG, stat.S_IFDIR)
                    or any(part.lower().endswith(('.app', '.appex'))
                           and (index != 1 or part != 'AsterionVeyra.app')
                           for index, part in enumerate(parts))):
                raise ValueError('Noncanonical ZIP path, link or nested app is unsupported')
        if (len(names) != len(set(names))
                or any(name.startswith('Payload/') and not name.startswith(APP)
                       and name != 'Payload/' for name in names)
                or any('.appex/' in name or '/_CodeSignature/' in name
                       or name.endswith('embedded.mobileprovision') for name in names)):
            raise ValueError('Only one unsigned app without extensions is supported')
        entry = archive.getinfo(APP + executable)
        if not 0 < entry.file_size <= 268_435_456:
            raise ValueError('Executable size outside bounds')
        check_unsigned_binary(archive.read(entry))
    item = {'version': version, 'buildVersion': str(build), 'date': date,
            'downloadURL': release_url(build), 'size': path.stat().st_size,
            'sha256': digest(path), 'minOSVersion': minimum}
    return {'name': 'Asterion Veyra', 'identifier': IDENTIFIER, 'sourceURL': SOURCE_URL,
            'apps': [{'name': 'Asterion Veyra', 'bundleIdentifier': BUNDLE,
                      'developerName': 'R347H4CK3R',
                      'localizedDescription': 'A personal AI assistant with voice, notes, and explicitly paired desktop access. Requires iOS 26 or later.',
                      'iconURL': f'https://raw.githubusercontent.com/{REPOSITORY}/{commit}/App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png',
                      'versions': [item],
                      'appPermissions': {'entitlements': [], 'privacy': privacy}}],
            'news': []}


def source_bytes(source):
    return (json.dumps(source, ensure_ascii=False, indent=2, sort_keys=True) + '\n').encode()


def make_provenance(source, run_id, attempt, commit):
    version = source['apps'][0]['versions'][0]
    return {'schemaVersion': 1, 'repository': REPOSITORY, 'commit': commit,
            'runID': run_id, 'runAttempt': attempt,
            'runURL': f'https://github.com/{REPOSITORY}/actions/runs/{run_id}/attempts/{attempt}',
            'tag': 'ios-build-' + version['buildVersion'],
            'build': int(version['buildVersion']), 'ipaSHA256': version['sha256'],
            'ipaSize': version['size'], 'sourceSHA256': hashlib.sha256(source_bytes(source)).hexdigest()}


def validate_previous(source, provenance, new_build):
    try:
        app = source['apps'][0]
        version = app['versions'][0]
        build = int(version['buildVersion'])
        valid = (source['identifier'] == IDENTIFIER and source['sourceURL'] == SOURCE_URL
                 and len(source['apps']) == 1 and app['bundleIdentifier'] == BUNDLE
                 and len(app['versions']) == 1 and version['downloadURL'] == release_url(build)
                 and provenance['schemaVersion'] == 1 and provenance['repository'] == REPOSITORY
                 and provenance['build'] == build and provenance['tag'] == f'ios-build-{build}'
                 and provenance['ipaSHA256'] == version['sha256']
                 and provenance['ipaSize'] == version['size']
                 and provenance['sourceSHA256'] == hashlib.sha256(source_bytes(source)).hexdigest()
                 and new_build > build)
    except (KeyError, IndexError, TypeError, ValueError):
        valid = False
    if not valid:
        raise ValueError('Existing source identity/provenance invalid, or update is not newer')
