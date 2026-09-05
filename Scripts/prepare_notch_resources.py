#!/usr/bin/env python3
"""Generate SwiftPM-compatible resources from the original Xcode catalogs."""
from pathlib import Path
import json
import shutil

root = Path(__file__).resolve().parent.parent / 'Vendor/DynamicNotch/DynamicNotch/Resources'
out = root / 'Generated'
out.mkdir(exist_ok=True)
catalog = json.loads((root / 'Localization/Localizable.xcstrings').read_text())
by_language = {}
for key, item in catalog['strings'].items():
    for language, value in item.get('localizations', {}).items():
        if 'stringUnit' in value:
            by_language.setdefault(language, {})[key] = value['stringUnit']['value']
for language, strings in by_language.items():
    directory = out / f'{language}.lproj'
    directory.mkdir(exist_ok=True)
    (directory / 'Localizable.strings').write_text('\n'.join(
        f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(value, ensure_ascii=False)};'
        for key, value in sorted(strings.items())) + '\n')
for path in (root / 'Assets.xcassets').rglob('*.imageset'):
    images = json.loads((path / 'Contents.json').read_text()).get('images', [])
    available = [i for i in images if i.get('filename')]
    if not available:
        continue
    # Preserve alternate appearance variants in the original catalog, while choosing
    # the universal/default image for SwiftPM's standalone resource lookup.
    selected = next((i for i in available if not i.get('appearances')), available[0])
    source = path / selected['filename']
    shutil.copy2(source, out / (path.stem + source.suffix))
print(f'Generated {len(by_language)} localization bundles and image resources.')
