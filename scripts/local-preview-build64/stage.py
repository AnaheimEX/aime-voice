#!/usr/bin/env python3
"""Assemble local AIME.app (with voice module) from the Xcode build, before signing."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
for name in ("root", "products", "destination", "cli"):
    parser.add_argument(name, type=pathlib.Path)
parser.add_argument("--build", required=True, help="Expected build number for all three components")
args = parser.parse_args()
root, products, destination, cli = (
    getattr(args, name) for name in ("root", "products", "destination", "cli")
)
if destination.exists():
    raise SystemExit("Staging destination already exists")

shutil.copytree(products / "AIME.app", destination, symlinks=True)
settings = destination / "Contents/Applications/AIME Settings.app"
settings.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(products / "AIME Settings.app", settings, symlinks=True)

shared = destination / "Contents/SharedSupport"
if (root / "build/SharedSupport").is_dir():
    shutil.copytree(root / "build/SharedSupport", shared, dirs_exist_ok=True, symlinks=True)
shutil.copytree(root / "SharedSupport", shared, dirs_exist_ok=True, symlinks=True)

helpers = destination / "Contents/Helpers"
helpers.mkdir(parents=True, exist_ok=True)
shutil.copy2(cli / "aime", helpers / "aime")
shutil.copytree(cli / "AIMEKit_AIMECore.bundle", helpers / "AIMEKit_AIMECore.bundle", dirs_exist_ok=True)
# SwiftPM records only @loader_path. librime.1.dylib is in Contents/Frameworks.
subprocess.run(
    ["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", str(helpers / "aime")],
    check=True,
)

expected_bundles = [
    (destination, "app.zool.inputmethod.aime"),
    (settings, "app.zool.aime.settings"),
    (destination / "Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voice"),
]
for bundle, expected_id in expected_bundles:
    path = bundle / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    if str(info.get("CFBundleVersion")) != args.build:
        raise SystemExit(f"Wrong build version in {bundle}: {info.get('CFBundleVersion')} != {args.build}")
    if info.get("CFBundleIdentifier") != expected_id:
        info["CFBundleIdentifier"] = expected_id
        path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))

# Xcode applies an intermediate ad-hoc signature. Restore the same pinned
# plugin inputs before regenerating the embedded inventory and local signing.
for library in (root / "Vendor/librime/lib/rime-plugins").glob("*.dylib"):
    shutil.copy2(library, destination / "Contents/Frameworks/rime-plugins" / library.name)
license_root = destination / "Contents/Resources/licenses"
license_root.mkdir(parents=True, exist_ok=True)
for name in ("fluidvoice-source.md",):
    shutil.copy2(root / "licenses" / name, license_root / name)
print(destination)
