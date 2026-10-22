"""Install a signed Preview, retaining the current app (as a zip) until the update succeeds."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import time

APP_NAME = "AIME Voice Preview.app"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage", type=pathlib.Path)
parser.add_argument("--helper", required=True, type=pathlib.Path)
parser.add_argument("--work", required=True, type=pathlib.Path)
args = parser.parse_args()
stage = args.stage.resolve(strict=True)
helper = args.helper.resolve(strict=True)
work = args.work.resolve(strict=True)
installed = pathlib.Path.home() / "Library/Input Methods" / APP_NAME


def registered_copies(bundle_id):
    """Paths LaunchServices lists for this bundle id, whether or not they still exist."""
    paths, path = [], None
    dump = subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True).stdout
    for line in dump.splitlines():
        if line.startswith("path:"):
            path = pathlib.Path(line.split(":", 1)[1].rsplit(" (0x", 1)[0].strip())
        elif re.fullmatch(r"identifier:\s+" + re.escape(bundle_id), line.strip()) and path is not None:
            paths.append(path)
    return paths


def retire(app, archive):
    """Keep an app that shares the installed bundle id only as a zip, which restores as APP_NAME.

    Any other copy with this bundle id (the staged one, the rollback copy, one dragged to
    /Applications) lets imklaunchagent resolve the input method to the wrong bundle or run
    two servers on one connection name; typing then stops working.
    """
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
    subprocess.run([LSREGISTER, "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(app)
    if app.parent != work and app.parent.parent == work:
        app.parent.rmdir()


def retire_quietly(app, archive):
    if app is not None and app.exists():
        try:
            retire(app, archive)
        except Exception as error:
            print("WARNING: could not archive", app, "-", error)


# A first install (new Mac) has no previous app to compare against or roll back to.
first_install = not installed.exists()
old_version = None if first_install else str(plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
new_version = str(plistlib.loads((stage / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
bundle_id = plistlib.loads((stage / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
if not new_version.isdecimal() or (old_version is not None and (not old_version.isdecimal() or int(new_version) <= int(old_version))):
    raise SystemExit("Expected a newer numeric build version")
if stage == installed.resolve() or installed.resolve() in stage.parents:
    raise SystemExit("Staged app must be separate from installed app")
# Rollback copy: work/previous-build<N>/AIME Voice Preview.app, archived as work/previous-build<N>.zip.
previous = None if first_install else work / f"previous-build{old_version}" / APP_NAME
previous_archive = None if first_install else work / f"previous-build{old_version}.zip"
if previous is not None and (previous.parent.exists() or previous_archive.exists()):
    raise SystemExit("Rollback destination already exists")
failed = work / "failed-install" / APP_NAME
failed_archive = work / "failed-install.zip"
stage_archive = pathlib.Path(str(stage) + ".zip")
# A second copy of this bundle id anywhere on disk is how typing broke before: refuse up front.
duplicates = sorted({str(path) for path in registered_copies(bundle_id)
                     if path.exists() and path.resolve() not in (installed.resolve(), stage)})
if duplicates:
    raise SystemExit("Another copy of " + bundle_id + " exists, which breaks the input method. Move it to the Trash "
                     "(or delete it), run `lsregister -u <path>` for it, then install again:\n  " + "\n  ".join(duplicates))
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(stage)], check=True)
current = subprocess.check_output([str(helper), "current"], text=True).strip()
(work / "previous-input-source.txt").write_text(current + "\n")

moved = False   # the old app now lives at `previous`
copied = False  # `installed` holds the new copy (possibly half-written)
try:
    subprocess.run([str(helper), "select", "com.apple.keylayout.ABC"], check=True)
    # Stop only processes belonging to the installed Preview, never another AIME.
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    for line in processes.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[1].startswith(str(installed) + "/"):
            try:
                os.kill(int(fields[0]), 15)
            except ProcessLookupError:
                pass
    time.sleep(1)
    if previous is not None:
        previous.parent.mkdir(parents=True)
        shutil.move(str(installed), str(previous))
        moved = True
    installed.parent.mkdir(parents=True, exist_ok=True)
    copied = True
    shutil.copytree(stage, installed, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    subprocess.run([str(helper), "register", str(installed)], check=True)
except BaseException:
    if copied and installed.exists():
        failed.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(installed), str(failed))
    if moved:
        shutil.move(str(previous), str(installed))
        subprocess.run([str(helper), "register", str(installed)])
    if current:
        subprocess.run([str(helper), "select", current])
    retire_quietly(failed, failed_archive)
    retire_quietly(stage, stage_archive)
    if previous is not None and not moved:
        shutil.rmtree(previous.parent, ignore_errors=True)
    raise
try:
    if current:
        subprocess.run([str(helper), "select", current], check=True)
finally:
    retire_quietly(stage, stage_archive)
    retire_quietly(previous, previous_archive)
for other in sorted({str(path) for path in registered_copies(bundle_id) if path.exists() and path.resolve() != installed.resolve()}):
    print("WARNING: another copy of", bundle_id, "is registered:", other, "- remove it, then: lsregister -u <path>")
subprocess.run(["open", "-a", str(installed)], check=True)
subprocess.run(["open", str(installed / "Contents/Applications/AIME Settings.app")], check=True)
print("Installed Build" + new_version + ("; first install" if previous is None else "; previous Build" + old_version + " retained at " + str(previous_archive)))
print("Restored input source:", current)
