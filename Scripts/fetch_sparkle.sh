#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Keep the CLI build and Xcode package pinned to the same verified release.
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
archive=".build/Sparkle-${sparkle_version}.tar.xz"
distribution=".build/sparkle-${sparkle_version}"
mkdir -p .build
if [[ ! -f "$archive" ]]; then
  curl --fail --location --silent --show-error \
    "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz" \
    -o "${archive}.download"
  printf '%s  %s\n' "$sparkle_sha256" "${archive}.download" | shasum -a 256 -c - >&2
  mv "${archive}.download" "$archive"
fi
printf '%s  %s\n' "$sparkle_sha256" "$archive" | shasum -a 256 -c - >&2
mkdir -p "$distribution"
tar -xJf "$archive" -C "$distribution"
printf '%s/%s\n' "$PWD" "$distribution"
