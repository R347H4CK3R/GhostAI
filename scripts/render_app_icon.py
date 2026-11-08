#!/usr/bin/env python3
"""Render the editable SVG with Inkscape/ImageMagick, then verify the icon set.

This is a design-maintenance command, not a build dependency. Generated PNGs
are committed so Xcode and CI need neither renderer.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / 'App/Assets.xcassets/AppIcon.appiconset'
SLOTS = {
    'iphone': {'20': (2, 3), '29': (2, 3), '40': (2, 3), '60': (2, 3)},
    'ipad': {'20': (1, 2), '29': (1, 2), '40': (1, 2), '76': (1, 2), '83.5': (2,)},
    'ios-marketing': {'1024': (1,)},
}


def main():
    inkscape = shutil.which('inkscape')
    convert = shutil.which('magick') or shutil.which('convert')
    if not inkscape or not convert:
        sys.exit('Regeneration needs Inkscape and ImageMagick. Committed PNGs need no rendering tools to build.')
    ICONSET.mkdir(parents=True, exist_ok=True)
    entries = []
    for idiom, sizes in SLOTS.items():
        for size, scales in sizes.items():
            for scale in scales:
                pixels = int(float(size) * scale)
                entries.append({'idiom': idiom, 'size': f'{size}x{size}', 'scale': f'{scale}x',
                                'filename': f'AppIcon-{pixels}.png'})
    with tempfile.TemporaryDirectory() as temp:
        rendered = Path(temp) / 'master.png'
        renderer_env = dict(os.environ, INKSCAPE_PROFILE_DIR=str(Path(temp) / 'inkscape'),
                            XDG_CACHE_HOME=str(Path(temp) / 'cache'))
        subprocess.run([inkscape, str(ROOT / 'Artwork/AppIcon.svg'), '--export-width=1024',
                        '--export-height=1024', f'--export-filename={rendered}'], env=renderer_env, check=True)
        for pixels in sorted({int(e['filename'][8:-4]) for e in entries}):
            subprocess.run([convert, str(rendered), '-resize', f'{pixels}x{pixels}',
                            '-background', '#101C36', '-alpha', 'remove', '-alpha', 'off',
                            '-strip', f'PNG24:{ICONSET / f"AppIcon-{pixels}.png"}'], check=True)
    metadata = {'info': {'author': 'xcode', 'version': 1}}
    (ICONSET.parent / 'Contents.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (ICONSET / 'Contents.json').write_text(json.dumps({'images': entries, **metadata}, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / 'scripts/verify_app_icon.py')], check=True)


if __name__ == '__main__':
    main()
