#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 <zip> [sparkle-bin-directory]" >&2
    exit 64
fi

project_directory="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$1" "$project_directory" "${2:-$project_directory/.build/sparkle-2.10.0/bin}" <<'PY'
import base64
import pathlib
import plistlib
import struct
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

archive, project, sparkle_bin = map(pathlib.Path, sys.argv[1:])
feed = project / "appcast.xml"
sign_update = sparkle_bin / "sign_update"
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
repository = "https://github.com/HY916-cn/ClaudeMeter"
feed_url = "https://raw.githubusercontent.com/HY916-cn/ClaudeMeter/main/appcast.xml"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(path, signature=None):
    command = [str(sign_update), "--verify", "--account", "com.huang.ClaudeMeter", str(path)]
    if signature is not None:
        command.append(signature)
    result = subprocess.run(command, capture_output=True, text=True)
    require(result.returncode == 0,
            f"Signature verification failed for {path.name}; check the signing account and regenerate the signed release.")


try:
    require(archive.is_file() and archive.suffix.lower() == ".zip", "Provide an existing release ZIP.")
    require(feed.is_file(), "Generate and sign appcast.xml before verification.")
    require(sign_update.is_file(), "Sparkle sign_update is missing; run Scripts/fetch_sparkle.sh.")
    verify(feed)
    config = plistlib.loads((project / "Config/CodexMeter-Info.plist").read_bytes())
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read("ClaudeMeter.app/Contents/Info.plist"))
        executable = info["CFBundleExecutable"]
        require("/" not in executable, "The bundle executable name is invalid.")
        with bundle.open(f"ClaudeMeter.app/Contents/MacOS/{executable}") as binary:
            header = binary.read(8)
        require(header == struct.pack("<II", 0xFEEDFACF, 0x0100000C),
                "The release executable must be an arm64 Mach-O binary.")
    require(info.get("CFBundleIdentifier") == "com.huang.ClaudeMeter", "Unexpected app bundle identifier.")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    require(archive.name == f"ClaudeMeter-{version}-macOS-arm64.zip", "ZIP filename must match the app version and arm64 release naming.")
    require(info.get("LSMinimumSystemVersion") == "13.0", "The app minimum macOS version must be 13.0.")
    for settings in (config, info):
        require(settings.get("SUFeedURL") == feed_url, "The update feed must use this repository's raw GitHub appcast.")
        require(settings.get("SURequireSignedFeed") is True, "Signed feed verification must be enabled.")
        require(settings.get("SUVerifyUpdateBeforeExtraction") is True, "Archive verification before extraction must be enabled.")
    require(info.get("SUPublicEDKey") == config.get("SUPublicEDKey"), "The app update public key differs from Config.")
    require(len(base64.b64decode(info["SUPublicEDKey"], validate=True)) == 32, "The update public key is invalid.")
    matches = []
    for item in ET.parse(feed).findall("./channel/item"):
        for enclosure in item.findall("enclosure"):
            filename = urllib.parse.unquote(urllib.parse.urlsplit(enclosure.get("url", "")).path.rsplit("/", 1)[-1])
            if filename == archive.name:
                matches.append((item, enclosure))
    require(len(matches) == 1, "The appcast must contain exactly one enclosure matching this ZIP filename.")
    item, enclosure = matches[0]
    require(item.findtext(namespace + "version") == build, "The appcast build differs from CFBundleVersion.")
    require(item.findtext(namespace + "shortVersionString") == version, "The appcast display version differs from the app.")
    require(item.findtext(namespace + "minimumSystemVersion") == "13.0", "The appcast minimum macOS version must be 13.0.")
    expected_url = f"{repository}/releases/download/v{version}/{archive.name}"
    require(enclosure.get("url") == expected_url, "The enclosure must point to this version's GitHub Release asset.")
    require(int(enclosure.get("length", "0")) == archive.stat().st_size, "The enclosure length differs from the release ZIP size.")
    signature = enclosure.get(namespace + "edSignature", "")
    require(len(base64.b64decode(signature, validate=True)) == 64, "The enclosure EdDSA signature is invalid.")
    verify(archive, signature)
    print(f"Verified ClaudeMeter {version} (build {build}): signed feed, signed arm64 ZIP, and update metadata.")
except (OSError, ValueError, KeyError, ET.ParseError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
    sys.exit(f"Update verification failed: {error}")
PY
