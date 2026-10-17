#!/bin/bash
set -euo pipefail

# Build the native app with the macOS Command Line Tools, including localized resources.
TASK_PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD_DIR="$TASK_PROJECT_DIR/.build/local"
TASK_APP="$TASK_PROJECT_DIR/dist/ClaudeMeter.app"
TASK_SDK="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
# macOS 27's State macro needs an Xcode-only plugin; the macOS 26 SDK uses property wrappers.
if [[ -z "${SDKROOT:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  TASK_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
mkdir -p "$TASK_BUILD_DIR" "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"

TASK_SOURCES=()
while IFS= read -r -d '' TASK_SOURCE; do
  TASK_SOURCES+=("$TASK_SOURCE")
done < <(find "$TASK_PROJECT_DIR/CodexMeter" -name '*.swift' -print0)

xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
  -sdk "$TASK_SDK" -target "$(uname -m)-apple-macos13.0" -O -whole-module-optimization \
  -module-cache-path "$TASK_BUILD_DIR/module-cache" \
  "${TASK_SOURCES[@]}" -lsqlite3 -o "$TASK_BUILD_DIR/ClaudeMeter"
cp "$TASK_BUILD_DIR/ClaudeMeter" "$TASK_APP/Contents/MacOS/ClaudeMeter"

python3 - "$TASK_PROJECT_DIR" "$TASK_APP" <<'PY'
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

root, app = map(Path, sys.argv[1:])
project = (root / 'CodexMeter.xcodeproj/project.pbxproj').read_text()
def setting(name):
    match = re.search(r'\b' + name + r' = ([^;]+);', project)
    if not match:
        raise SystemExit(f'Missing project setting: {name}')
    return match.group(1).strip('"')

info = plistlib.loads((root / 'Config/CodexMeter-Info.plist').read_bytes())
info.update({
    'CFBundleDevelopmentRegion': 'en',
    'CFBundleExecutable': 'ClaudeMeter',
    'CFBundleIdentifier': setting('PRODUCT_BUNDLE_IDENTIFIER'),
    'CFBundleName': 'ClaudeMeter',
    'CFBundleDisplayName': 'ClaudeMeter',
    'CFBundleShortVersionString': setting('MARKETING_VERSION'),
    'CFBundleVersion': setting('CURRENT_PROJECT_VERSION'),
    'LSMinimumSystemVersion': '13.0',
    'CFBundleIconFile': 'AppIcon',
})
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
catalog = json.loads((root / 'CodexMeter/Localizable.xcstrings').read_text())
languages = {}
for key, entry in catalog['strings'].items():
    for language, localization in entry.get('localizations', {}).items():
        if 'stringUnit' not in localization:
            raise SystemExit(f'Unsupported localization variant: {key}/{language}')
        languages.setdefault(language, {})[key] = localization['stringUnit']['value']
for language, strings in languages.items():
    directory = app / 'Contents/Resources' / f'{language}.lproj'
    directory.mkdir(parents=True, exist_ok=True)
    (directory / 'Localizable.strings').write_bytes(plistlib.dumps(strings, fmt=plistlib.FMT_BINARY))

iconset = root / '.build/local/AppIcon.iconset'
iconset.mkdir(parents=True, exist_ok=True)
assets = root / 'CodexMeter/Assets.xcassets/AppIcon.appiconset'
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        suffix = '@2x' if scale == 2 else ''
        shutil.copy2(assets / f'AppIcon-{size * scale}.png', iconset / f'icon_{size}x{size}{suffix}.png')
subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(app / 'Contents/Resources/AppIcon.icns')], check=True)
shutil.copy2(root / 'LICENSE', app / 'Contents/Resources/LICENSE')
PY

codesign --force --sign - "$TASK_APP"
codesign --verify --deep --strict "$TASK_APP"
printf '%s\n' "$TASK_APP"
