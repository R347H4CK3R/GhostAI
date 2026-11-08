#!/usr/bin/env python3
"""Check source icons and, optionally, the compiled icon payload in an IPA.

Uses only Python's standard library. Packaging checks are not a device-install test.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import zipfile
import zlib


REQUIRED_SLOTS = {
    ('iphone', '20x20', '2x'), ('iphone', '20x20', '3x'),
    ('iphone', '29x29', '2x'), ('iphone', '29x29', '3x'),
    ('iphone', '40x40', '2x'), ('iphone', '40x40', '3x'),
    ('iphone', '60x60', '2x'), ('iphone', '60x60', '3x'),
    ('ipad', '20x20', '1x'), ('ipad', '20x20', '2x'),
    ('ipad', '29x29', '1x'), ('ipad', '29x29', '2x'),
    ('ipad', '40x40', '1x'), ('ipad', '40x40', '2x'),
    ('ipad', '76x76', '1x'), ('ipad', '76x76', '2x'),
    ('ipad', '83.5x83.5', '2x'), ('ios-marketing', '1024x1024', '1x'),
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def png_metadata(data, name, require_rgb=False):
    require(data[:8] == b'\x89PNG\r\n\x1a\n', f'{name}: invalid PNG signature')
    offset, dimensions, pixel_data = 8, None, False
    while offset < len(data):
        require(offset + 12 <= len(data), f'{name}: truncated PNG chunk')
        size, tag = struct.unpack('>I4s', data[offset:offset + 8])
        payload = data[offset + 8:offset + 8 + size]
        require(offset + 12 + size <= len(data), f'{name}: truncated {tag!r}')
        crc = struct.unpack('>I', data[offset + 8 + size:offset + 12 + size])[0]
        require(zlib.crc32(tag + payload) == crc, f'{name}: bad {tag!r} CRC')
        if tag == b'IHDR':
            require(size == 13, f'{name}: invalid IHDR')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            dimensions = (width, height)
            require(width > 0 and height > 0, f'{name}: zero size')
            if require_rgb:
                require(depth == 8 and color == 2, f'{name}: must be 8-bit RGB with no alpha channel')
                require(compression == 0 and filtering == 0 and interlace == 0, f'{name}: unsupported PNG encoding')
        if require_rgb:
            require(tag != b'tRNS', f'{name}: contains transparency')
        if tag == b'IDAT':
            pixel_data = pixel_data or size > 0
        offset += 12 + size
        if tag == b'IEND':
            require(dimensions is not None and pixel_data, f'{name}: missing image data')
            return dimensions
    raise ValueError(f'{name}: missing IEND')


def verify_source(root):
    catalog = root / 'App/Assets.xcassets'
    iconset = catalog / 'AppIcon.appiconset'
    require((catalog / 'Contents.json').is_file(), 'Asset catalog Contents.json is missing')
    require((iconset / 'Contents.json').is_file(), 'AppIcon.appiconset/Contents.json is missing')
    entries = json.loads((iconset / 'Contents.json').read_text())['images']
    slots = [(e.get('idiom'), e.get('size'), e.get('scale')) for e in entries]
    require(len(slots) == len(set(slots)), 'AppIcon has duplicate size/scale entries')
    require(set(slots) == REQUIRED_SLOTS, f'Incorrect AppIcon slots; missing: {REQUIRED_SLOTS - set(slots)}')
    checked = set()
    for entry in entries:
        filename = entry.get('filename', '')
        require(filename and Path(filename).name == filename, 'An icon filename is missing or unsafe')
        path = iconset / filename
        require(path.is_file(), f'Missing {path}')
        points = entry['size'].split('x')
        scale = float(entry['scale'][:-1])
        expected = tuple(int(float(p) * scale) for p in points)
        actual = png_metadata(path.read_bytes(), filename, require_rgb=True)
        require(actual == expected, f'{filename}: expected {expected}, got {actual}')
        checked.add(filename)
    project = (root / 'project.yml').read_text()
    require(re.search(r'^\s+ASSETCATALOG_COMPILER_APPICON_NAME:\s*[\"\']?AppIcon[\"\']?\s*$', project, re.M),
            'project.yml must select ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon')
    print(f'PASS source: {len(slots)} iPhone/iPad/marketing slots, {len(checked)} opaque RGB PNGs with correct dimensions')


def verify_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        plists = [n for n in names if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
        require(len(plists) == 1, 'IPA must contain exactly one top-level application Info.plist')
        plist_name = plists[0]
        info = plistlib.loads(archive.read(plist_name))
        prefix = plist_name.rsplit('/', 1)[0] + '/'
        assets = prefix + 'Assets.car'
        require(assets in names and archive.getinfo(assets).file_size > 0, 'IPA is missing compiled Assets.car')
        families = info.get('UIDeviceFamily', [])
        require(1 in families, 'IPA does not declare iPhone support')
        for key in ['CFBundleIcons'] + (['CFBundleIcons~ipad'] if 2 in families else []):
            primary = info.get(key, {}).get('CFBundlePrimaryIcon', {})
            require(primary.get('CFBundleIconName') == 'AppIcon', f'{key} is missing primary AppIcon metadata')
            files = primary.get('CFBundleIconFiles', [])
            require(files, f'{key} is missing CFBundleIconFiles')
            for base in files:
                stem = base[:-4] if base.endswith('.png') else base
                matches = [n for n in names if re.fullmatch(re.escape(prefix + stem) + r'(?:@[123]x)?(?:~(?:iphone|ipad))?\.png', n)]
                require(matches, f'{key}: declared icon {base} has no bundled PNG')
                for match in matches:
                    width, height = png_metadata(archive.read(match), match)
                    require(width == height, f'{match}: packaged icon is not square')
        # Universal unthinned archives must carry the iPhone 60pt icons at both scales.
        for suffix, pixels in [('@2x.png', 120), ('@3x.png', 180)]:
            candidates = [n for n in names if n.startswith(prefix + 'AppIcon') and n.endswith(suffix)]
            require(any(png_metadata(archive.read(n), n) == (pixels, pixels) for n in candidates),
                    f'IPA is missing the {pixels}px iPhone home-screen icon')
        version = info.get('CFBundleShortVersionString', '?')
        build = info.get('CFBundleVersion', '?')
        print(f'PASS IPA: {version} ({build}), compiled Assets.car, primary icon metadata and iPhone icon PNGs present')
        print('This verifies archive packaging, not signing, installation or appearance on a physical device.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('--ipa', type=Path, help='Also inspect an unthinned universal device IPA')
    parser.add_argument('--ipa-only', action='store_true', help='Skip source checks, useful for older IPA diagnosis')
    args = parser.parse_args()
    try:
        require(not args.ipa_only or args.ipa, '--ipa-only requires --ipa')
        if not args.ipa_only:
            verify_source(args.source_root)
        if args.ipa:
            verify_ipa(args.ipa)
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
