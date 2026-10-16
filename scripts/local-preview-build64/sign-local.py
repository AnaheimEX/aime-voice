import pathlib
import plistlib
import subprocess
import sys

app, reference, root = map(pathlib.Path, sys.argv[1:])
identity = "79C9B3548DA35EC4B1DD2E8B4BF80E07D58F68B2"
components = [
    ("Contents/Applications/AIME Settings.app", "Apps/AIMESettings/AIMESettings.entitlements"),
    ("Contents/XPCServices/AIME Voice.xpc", "Apps/AIMEVoiceService/AIMEVoice.entitlements"),
    (".", "Apps/AIME/AIME.entitlements"),
]
for relative, entitlement_path in components:
    bundle = app / relative
    old = subprocess.run(["codesign", "-d", "-r-", str(reference / relative)], capture_output=True, text=True, check=True)
    requirement = next(line.split("designated => ", 1)[1] for line in (old.stdout + old.stderr).splitlines() if "designated => " in line)
    entitlements = plistlib.loads((root / entitlement_path).read_bytes())
    # Local self-signed certificates have no Team ID. Allow only these signed
    # local Preview processes to load their embedded native ASR framework.
    if relative != ".":
        entitlements["com.apple.security.cs.disable-library-validation"] = True
    local = app.parent / (bundle.name + ".local.entitlements")
    local.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
                    "--entitlements", str(local), str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Local framework entitlements applied; all three original signing requirements preserved")
