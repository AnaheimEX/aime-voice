#!/usr/bin/env python3
"""Sign a staged Voice Preview; never build, install, or manage keychains.

Default: read-only preflight and print commands. --execute uses the explicitly
chosen certificate's private key via codesign, and requires prior user consent.
Use the installed app as --reference on EVERY update. An ad-hoc reference needs
--allow-identity-migration once; subsequent updates must keep all three DRs.
This check protects identity continuity, not a guarantee of TCC authorization.
"""

import argparse
import pathlib
import plistlib
import re
import shlex
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parent.parent
BUNDLES = (
    ("Contents/Applications/AIME Settings.app", "app.zool.aime.voicepreview.settings",
     "Apps/AIMESettings/AIMESettings.entitlements"),
    ("Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voicepreview.service",
     "Local/AIMEVoiceService/AIMEVoice.entitlements"),
    (".", "app.zool.inputmethod.aime.voicepreview", "Apps/AIME/AIME.entitlements"),
)


def fail(message):
    raise RuntimeError(message)


def run(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode:
        fail(f"{shlex.join(map(str, arguments))}\n{result.stdout}{result.stderr}")
    return result.stdout + result.stderr


def beneath(path, parent):
    return path != parent and parent in path.parents


def inspect_layout(app):
    versions = set()
    for relative, identifier, entitlements in BUNDLES:
        bundle = (app / relative).resolve(strict=True)
        if bundle != app and not beneath(bundle, app):
            fail(f"Bundle escapes staging/reference root: {bundle}")
        info_path = bundle / "Contents/Info.plist"
        if not beneath(info_path.resolve(strict=True), bundle):
            fail(f"Info.plist escapes bundle: {bundle}")
        info = plistlib.loads(info_path.read_bytes())
        if info.get("CFBundleIdentifier") != identifier:
            fail(f"Unexpected bundle ID: {bundle}")
        executable_name = info.get("CFBundleExecutable", "")
        if not executable_name or pathlib.Path(executable_name).name != executable_name:
            fail(f"Invalid executable name: {bundle}")
        executable = (bundle / "Contents/MacOS" / executable_name).resolve(strict=True)
        if not executable.is_file() or not beneath(executable, bundle):
            fail(f"Invalid executable path: {bundle}")
        version = str(info.get("CFBundleVersion", ""))
        if not version:
            fail(f"Missing build version: {bundle}")
        versions.add(version)
        if not (ROOT / entitlements).is_file():
            fail(f"Missing entitlements: {entitlements}")
    if len(versions) != 1:
        fail(f"Three bundles must have the same build version: {app}")


def signature(bundle):
    output = run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", str(bundle)])
    match = re.search(r"^#?\s*designated => (.+)$", output, re.MULTILINE)
    if not match:
        fail(f"Missing designated requirement: {bundle}")
    requirement = match.group(1).strip()
    # Read public bundle metadata only. Do not enumerate identities/keychains.
    certificate_backed = (
        "Signature=adhoc" not in output
        and re.search(r"^Authority=.+$", output, re.MULTILINE) is not None
        and re.search(r"\b(anchor|certificate)\b", requirement) is not None
    )
    return requirement, certificate_backed


def reference_state(reference):
    inspect_layout(reference)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(reference)])
    return {relative: signature(reference / relative) for relative, _, _ in BUNDLES}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=pathlib.Path,
                        help="Complete staged .app inside this repository or its sibling dist directory; modified only with --execute")
    parser.add_argument("--reference", required=True, type=pathlib.Path,
                        help="Existing installed Preview; read-only identity baseline")
    parser.add_argument("--identity", required=True,
                        help="Explicit certificate SHA-1 fingerprint (40 hex digits); no name lookup/ad-hoc")
    parser.add_argument("--allow-identity-migration", action="store_true",
                        help="Explicit one-time change of signing identity; existing TCC grant may not transfer")
    parser.add_argument("--execute", action="store_true",
                        help="Actually sign staged app using private key; obtain user authorization first")
    parser.add_argument("--timestamp", choices=("none", "secure"), default="none",
                        help="none for local use; secure for Developer ID distribution, without fallback")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.identity):
        fail("--identity must be an explicit certificate fingerprint; ad-hoc/automatic selection is forbidden")
    app = args.app.expanduser().resolve(strict=True)
    reference = args.reference.expanduser().resolve(strict=True)
    staging_roots = (ROOT, (ROOT.parent / "dist").resolve())
    if app.suffix != ".app" or not any(beneath(app, root) for root in staging_roots):
        fail("--app must be a staged .app inside this repository or ROOT.parent/dist")
    if app == reference or beneath(app, reference) or beneath(reference, app):
        fail("Staged app and reference must be separate, non-overlapping directories")
    inspect_layout(app)
    before = reference_state(reference)
    if any(not stable for _, stable in before.values()) and not args.allow_identity_migration:
        fail("Reference lacks certificate-backed identity. One-time --allow-identity-migration required")
    if args.allow_identity_migration:
        print("IDENTITY MIGRATION: previous authorization may not transfer; do not repeat on normal updates.")
    commands = []
    for relative, _, entitlements in BUNDLES:
        commands.append([
            "/usr/bin/codesign", "--force", "--options", "runtime",
            "--timestamp" if args.timestamp == "secure" else "--timestamp=none",
            "--sign", args.identity.upper(), "--entitlements", str(ROOT / entitlements),
            str(app / relative),
        ])
    for command in commands:
        print(shlex.join(command))
    if not args.execute:
        print("PREFLIGHT ONLY: no signing/keychain access. Certificate availability and new DRs remain unchecked.")
        return
    # Sign inside out, with codesign's certificate-derived DR. No custom relaxed
    # requirements, --deep signing, fallback identity, or automatic trust changes.
    for command in commands:
        run(command)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    for relative, identifier, _ in BUNDLES:
        bundle = app / relative
        run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)])
        requirement, stable = signature(bundle)
        if not stable:
            fail(f"Signed result lacks certificate-backed DR: {identifier}; do not deploy")
        previous, _ = before[relative]
        if requirement != previous:
            if not args.allow_identity_migration:
                fail(f"DR changed for {identifier}; do not deploy\nBefore: {previous}\nAfter: {requirement}")
            print(f"MIGRATED {identifier}\nBefore: {previous}\nAfter: {requirement}")
        else:
            # Evaluate the previous identity against the new signed artifact too.
            run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + previous, str(bundle)])
            print(f"UNCHANGED {identifier}: {requirement}")
    if reference_state(reference) != before:
        fail("Reference identity changed during signing; do not deploy")
    print("Verified staged signatures. Reference untouched; nothing installed. No TCC grant was tested.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
