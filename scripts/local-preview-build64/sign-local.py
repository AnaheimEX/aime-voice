import pathlib
import plistlib
import re
import subprocess
import sys

app, reference, root = map(pathlib.Path, sys.argv[1:])
identity = "AB8AB59CBD6D11B399BCFB9E9FDF06927DE61068"  # "AIME Local Code Signing", this Mac's login keychain
components = [
    ("Contents/Applications/AIME Settings.app", "Apps/AIMESettings/AIMESettings.entitlements"),
    ("Contents/XPCServices/AIME Voice.xpc", "Local/AIMEVoiceService/AIMEVoice.entitlements"),
    (".", "Apps/AIME/AIME.entitlements"),
]
changed_certificates = set()
for relative, entitlement_path in components:
    bundle = app / relative
    old = subprocess.run(["codesign", "-d", "-r-", str(reference / relative)], capture_output=True, text=True, check=True)
    requirement = next(line.split("designated => ", 1)[1] for line in (old.stdout + old.stderr).splitlines() if "designated => " in line)
    # Keep the reference's identifier; the certificate is whichever local one signs on this Mac.
    # This makes the verify below check the identifier only, so say when the certificate really changed.
    previous = re.search(r'certificate leaf = H"([0-9a-f]+)"', requirement)
    if previous and previous.group(1) != identity.lower():
        changed_certificates.add(previous.group(1))
    requirement = re.sub(r'certificate leaf = H"[0-9a-f]+"', f'certificate leaf = H"{identity.lower()}"', requirement)
    entitlements = plistlib.loads((root / entitlement_path).read_bytes())
    # Local self-signed certificates have no Team ID. Allow only these signed
    # local Preview processes to load their embedded native ASR framework.
    if relative != ".":
        entitlements["com.apple.security.cs.disable-library-validation"] = True
    else:
        # The voice host owns microphone access; upstream's AIME.entitlements stays unchanged.
        entitlements["com.apple.security.device.audio-input"] = True
    local = app.parent / (bundle.name + ".local.entitlements")
    local.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
                    "--entitlements", str(local), str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print("Local framework entitlements applied; all three signing identifiers preserved")
if changed_certificates:
    print("NOTE: the reference was signed with a different certificate (" + ", ".join(sorted(changed_certificates)) +
          "). macOS treats this build as a new app: grant microphone, accessibility and speech recognition again.")
