import pathlib
import filecmp
import plistlib
import uuid
import subprocess
import sys
import tempfile


def same_code(first, second, temporary_root):
    if filecmp.cmp(first, second, shallow=False):
        return True
    def architectures(path):
        return subprocess.check_output(["lipo", "-archs", str(path)], text=True).split()
    arches = architectures(first)
    if set(arches) != set(architectures(second)):
        return False
    # Xcode may re-sign only the top-level copy, changing __LINKEDIT allocation.
    # Normalize signatures on temporary slices; compare every remaining byte.
    with tempfile.TemporaryDirectory(prefix="framework-compare-", dir=temporary_root) as directory:
        for arch in arches:
            copies = []
            for index, source in enumerate((first, second)):
                copy = pathlib.Path(directory) / (str(index) + "-" + arch)
                subprocess.run(["lipo", str(source), "-thin", arch, "-output", str(copy)], check=True)
                subprocess.run(["codesign", "--remove-signature", str(copy)], check=True)
                subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                                "--identifier", "com.transcribe.CTranscribe", str(copy)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                copies.append(copy)
            if not filecmp.cmp(*copies, shallow=False):
                return False
    return True


app = pathlib.Path(sys.argv[1])
identity = "79C9B3548DA35EC4B1DD2E8B4BF80E07D58F68B2"
# Sign embedded native dependencies before their containing bundles.
for framework in sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True):
    if framework.name == "CTranscribe.framework":
        # Upstream ZIP materializes versioned framework symlinks as copies.
        # Preserve identical duplicates outside the app, then restore canonical links.
        canonical = framework / "Versions/A"
        displaced = app.parent / ("framework-layout-" + uuid.uuid4().hex)
        displaced.mkdir()
        for relative, target in (("Versions/Current", "A"),
                                 ("CTranscribe", "Versions/Current/CTranscribe"),
                                 ("Resources", "Versions/Current/Resources")):
            path = framework / relative
            if path.is_symlink():
                continue
            if path.is_file() and not same_code(path, canonical / path.name, app.parent):
                raise SystemExit("Unexpected different framework binary")
            path.rename(displaced / path.name)
            path.symlink_to(target, target_is_directory=relative != "CTranscribe")
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity, str(framework)], check=True)
for library in sorted(app.rglob("*.dylib")):
    if not any(parent.suffix == ".framework" for parent in library.parents):
        subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity, str(library)], check=True)
resources = app / "Contents/Helpers/AIMEKit_AIMECore.bundle"
subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity, str(resources)], check=True)
helper = app / "Contents/Helpers/aime"
# The helper loads Contents/Frameworks/librime.1.dylib. Hardened runtime rejects
# that library unless validation is disabled, the same as the input method.
helper_entitlements = app.parent / "aime-helper.local.entitlements"
helper_entitlements.write_bytes(plistlib.dumps({
    "com.apple.security.cs.disable-library-validation": True,
}))
subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
                "--entitlements", str(helper_entitlements), str(helper)], check=True)
helper_entitlements.unlink()
