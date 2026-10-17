#!/bin/zsh

set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: $0 <ClaudeMeter.app>" >&2
    exit 64
fi

app_path="$1"

if [[ ! -d "$app_path" || "${app_path:e}" != "app" ]]; then
    echo "App bundle not found: $app_path" >&2
    exit 66
fi

codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

echo "Ad-hoc signature verified: $app_path"
