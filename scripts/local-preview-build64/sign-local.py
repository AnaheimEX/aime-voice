#!/usr/bin/env python3
"""Sign AIME.app, AIME Settings.app, and AIME Voice.xpc with the local certificate while keeping upstream bundle IDs."""
import pathlib
import plistlib
import subprocess
import sys

app, root = map(pathlib.Path, sys.argv[1:3])
identity = "AB8AB59CBD6D11B399BCFB9E9FDF06927DE61068"  # "AIME Local Code Signing", this Mac's login keychain
components = [
    ("Contents/Applications/AIME Settings.app", "app.zool.aime.settings", "Apps/AIMESettings/AIMESettings.entitlements"),
    ("Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voice", "Local/AIMEVoiceService/AIMEVoice.entitlements"),
    (".", "app.zool.inputmethod.aime", "Apps/AIME/AIME.entitlements"),
]
for relative, bundle_id, entitlement_path in components:
    bundle = app / relative
    requirement = f'identifier "{bundle_id}" and certificate leaf = H"{identity.lower()}"'
    entitlements = plistlib.loads((root / entitlement_path).read_bytes())
    # Local self-signed certificates have no Team ID. Allow these signed
    # processes to load their embedded native ASR framework.
    if relative != ".":
        entitlements["com.apple.security.cs.disable-library-validation"] = True
    else:
        # The voice host owns microphone access; upstream's AIME.entitlements stays unchanged.
        entitlements["com.apple.security.device.audio-input"] = True
    local = app.parent / (bundle.name + ".local.entitlements")
    local.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(
        [
            "codesign",
            "--force",
            "--options",
            "runtime",
            "--timestamp=none",
            "--sign",
            identity,
            "--entitlements",
            str(local),
            str(bundle),
        ],
        check=True,
    )
    subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Local framework entitlements applied; upstream bundle identifiers preserved")
