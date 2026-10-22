"""Install a signed Preview, retaining the current app until the update succeeds."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage", type=pathlib.Path)
parser.add_argument("--helper", required=True, type=pathlib.Path)
parser.add_argument("--work", required=True, type=pathlib.Path)
args = parser.parse_args()
stage = args.stage.resolve(strict=True)
helper = args.helper.resolve(strict=True)
work = args.work.resolve(strict=True)
installed = pathlib.Path.home() / "Library/Input Methods/AIME Voice Preview.app"
lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def retire(app):
    """Keep an app that shares the installed bundle id only as a zip.

    Any other copy with this bundle id (the staged one, the rollback copy, one dragged to
    /Applications) lets imklaunchagent resolve the input method to the wrong bundle or run
    two servers on one connection name; typing then stops working.
    """
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(app) + ".zip"], check=True)
    subprocess.run([lsregister, "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(app)


# A first install (new Mac) has no previous app to compare against or roll back to.
first_install = not installed.exists()
old_version = None if first_install else str(plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
new_version = str(plistlib.loads((stage / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
if not new_version.isdecimal() or (old_version is not None and (not old_version.isdecimal() or int(new_version) <= int(old_version))):
    raise SystemExit("Expected a newer numeric build version")
if stage == installed.resolve() or installed.resolve() in stage.parents:
    raise SystemExit("Staged app must be separate from installed app")
previous = None if first_install else work / ("previous-build" + old_version + ".app")
if previous is not None and previous.exists():
    raise SystemExit("Rollback destination already exists")
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(stage)], check=True)
current = subprocess.check_output([str(helper), "current"], text=True).strip()
(work / "previous-input-source.txt").write_text(current + "\n")
subprocess.run([str(helper), "select", "com.apple.keylayout.ABC"], check=True)
# Stop only processes belonging to the installed Preview, never another AIME.
processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
for line in processes.splitlines():
    fields = line.strip().split(maxsplit=1)
    if len(fields) == 2 and fields[1].startswith(str(installed) + "/"):
        os.kill(int(fields[0]), 15)
time.sleep(1)
if previous is not None:
    installed.rename(previous)
try:
    installed.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(stage, installed, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    subprocess.run([str(helper), "register", str(installed)], check=True)
except BaseException:
    failed = work / "failed-install.app"
    if installed.exists():
        installed.rename(failed)
    if previous is not None:
        previous.rename(installed)
        subprocess.run([str(helper), "register", str(installed)])
    if current:
        subprocess.run([str(helper), "select", current])
    for leftover in (failed, stage):
        if leftover.exists():
            try:
                retire(leftover)
            except Exception as error:
                print("WARNING: could not archive", leftover, "-", error)
    raise
if current:
    subprocess.run([str(helper), "select", current], check=True)
retire(stage)
if previous is not None:
    retire(previous)
bundle_id = plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
others = []
path = None
for line in subprocess.run([lsregister, "-dump"], capture_output=True, text=True).stdout.splitlines():
    if line.startswith("path:"):
        path = line.split(":", 1)[1].rsplit(" (0x", 1)[0].strip()
    elif re.fullmatch(r"identifier:\s+" + re.escape(bundle_id), line.strip()) and path and pathlib.Path(path) != installed:
        others.append(path)
for other in sorted(set(others)):
    print("WARNING: another copy of", bundle_id, "is registered:", other, "- remove it, then: lsregister -u <path>")
subprocess.run(["open", "-a", str(installed)], check=True)
subprocess.run(["open", str(installed / "Contents/Applications/AIME Settings.app")], check=True)
print("Installed Build" + new_version + ("; first install" if previous is None else "; previous Build" + old_version + " retained at " + str(previous) + ".zip"))
print("Restored input source:", current)
