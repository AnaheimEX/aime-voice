#!/usr/bin/env python3
"""Assemble local Preview from the current full Xcode build, before signing."""
import argparse
import pathlib
import plistlib
import shutil

parser = argparse.ArgumentParser(description=__doc__)
for name in ("root", "products", "reference", "destination", "cli"):
    parser.add_argument(name, type=pathlib.Path)
parser.add_argument("--build", required=True, help="Expected build number for all three components")
args = parser.parse_args()
root, products, reference, destination, cli = (getattr(args, name) for name in
    ("root", "products", "reference", "destination", "cli"))
if destination.exists():
    raise SystemExit("Staging destination already exists")
shutil.copytree(products / "AIME.app", destination, symlinks=True)
settings = destination / "Contents/Applications/AIME Settings.app"
settings.parent.mkdir(parents=True, exist_ok=True)
shutil.copytree(products / "AIME Settings.app", settings, symlinks=True)
shared = destination / "Contents/SharedSupport"
shutil.copytree(reference / "Contents/SharedSupport", shared, dirs_exist_ok=True, symlinks=True)
shutil.copytree(root / "SharedSupport", shared, dirs_exist_ok=True, symlinks=True)
helpers = destination / "Contents/Helpers"
helpers.mkdir(parents=True, exist_ok=True)
shutil.copy2(cli / "aime", helpers / "aime")
shutil.copytree(cli / "AIMEKit_AIMECore.bundle", helpers / "AIMEKit_AIMECore.bundle", dirs_exist_ok=True)

bundles = [(destination, "app.zool.inputmethod.aime.voicepreview"),
           (settings, "app.zool.aime.voicepreview.settings"),
           (destination / "Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voicepreview.service")]
for bundle, identifier in bundles:
    path = bundle / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    if str(info["CFBundleVersion"]) != args.build:
        raise SystemExit(f"Wrong build version: {bundle}")
    info["CFBundleIdentifier"] = identifier
    if bundle == destination:
        old = plistlib.loads((reference / "Contents/Info.plist").read_bytes())
        for key in ("CFBundleName", "CFBundleDisplayName", "InputMethodConnectionName",
                    "TISInputSourceID", "ComponentInputModeDict", "AIMEVoiceServiceIdentifier"):
            info[key] = old[key]
    path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))
# Xcode applies an intermediate ad-hoc signature. Restore the same pinned
# plugin inputs before regenerating the embedded inventory and local signing.
for library in (root / "Vendor/librime/lib/rime-plugins").glob("*.dylib"):
    shutil.copy2(library, destination / "Contents/Frameworks/rime-plugins" / library.name)
license_root = destination / "Contents/Resources/licenses"
for name in ("fluidvoice-source.md",):
    shutil.copy2(root / "licenses" / name, license_root / name)
print(destination)
