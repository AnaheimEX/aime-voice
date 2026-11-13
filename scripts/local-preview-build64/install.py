#!/usr/bin/env python3
"""Install signed AIME.app into ~/Library/Input Methods/AIME.app, replacing the old app cleanly with no leftover backups."""
import argparse
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import time

APP_NAME = "AIME.app"
LEGACY_PREVIEW_NAME = "AIME Voice Preview.app"
BUNDLE_ID = "app.zool.inputmethod.aime"
LEGACY_BUNDLE_ID = "app.zool.inputmethod.aime.voicepreview"
INPUT_MODE_ID = "app.zool.inputmethod.aime.hans"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage", type=pathlib.Path)
parser.add_argument("--helper", required=True, type=pathlib.Path)
parser.add_argument("--work", required=True, type=pathlib.Path)
args = parser.parse_args()
stage = args.stage.resolve(strict=True)
helper = args.helper.resolve(strict=True)
work = args.work.resolve(strict=True)
home = pathlib.Path.home()
input_methods_dir = home / "Library/Input Methods"
installed = input_methods_dir / APP_NAME
legacy_preview = input_methods_dir / LEGACY_PREVIEW_NAME


def registered_copies(bundle_id):
    """Paths LaunchServices lists for this bundle id."""
    paths, path = [], None
    dump = subprocess.run([LSREGISTER, "-dump"], capture_output=True, text=True).stdout
    for line in dump.splitlines():
        if line.startswith("path:"):
            path = pathlib.Path(line.split(":", 1)[1].rsplit(" (0x", 1)[0].strip())
        elif re.fullmatch(r"identifier:\s+" + re.escape(bundle_id), line.strip()) and path is not None:
            paths.append(path)
    return paths


def stop_processes(prefix: str):
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    for line in processes.splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) == 2 and fields[1].startswith(prefix):
            try:
                os.kill(int(fields[0]), 15)
            except ProcessLookupError:
                pass


def migrate_legacy_preview_data():
    """If ~/Library/AIME Voice Preview/Rime exists, migrate it to ~/Library/AIME/Rime and remove the preview dir."""
    legacy_data = home / "Library/AIME Voice Preview"
    target_data = home / "Library/AIME"
    legacy_logs = home / "Library/Logs/AIME Voice Preview"
    if legacy_data.is_dir():
        if (legacy_data / "Rime").is_dir():
            target_data.mkdir(parents=True, exist_ok=True)
            if (target_data / "Rime").exists():
                shutil.rmtree(target_data / "Rime")
            shutil.move(str(legacy_data / "Rime"), str(target_data / "Rime"))
        shutil.rmtree(legacy_data, ignore_errors=True)
    if legacy_logs.is_dir():
        shutil.rmtree(legacy_logs, ignore_errors=True)


def unregister_bundle_tree(app_path: pathlib.Path):
    """Unregister a bundle and nested Settings/XPC bundles (even if already absent from disk)."""
    for target in (
        app_path / "Contents/Applications/AIME Settings.app",
        app_path / "Contents/XPCServices/AIME Voice.xpc",
        app_path,
    ):
        subprocess.run([LSREGISTER, "-u", str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def remove_legacy_preview_app():
    """Disable, unregister, and delete the legacy AIME Voice Preview.app, symlinks, and TCC entries."""
    for mode in (f"{LEGACY_BUNDLE_ID}.hans", LEGACY_BUNDLE_ID):
        subprocess.run([str(helper), "disable", mode], check=False)
    if legacy_preview.exists():
        stop_processes(str(legacy_preview) + "/")
        shutil.rmtree(legacy_preview, ignore_errors=True)
    unregister_bundle_tree(legacy_preview)
    legacy_settings_link = pathlib.Path("/Applications/AIME Settings.app")
    if legacy_settings_link.is_symlink() and "AIME Voice Preview.app" in os.readlink(legacy_settings_link):
        legacy_settings_link.unlink()
    for bundle_id in (LEGACY_BUNDLE_ID, "app.zool.aime.voicepreview.settings"):
        for path in registered_copies(bundle_id):
            unregister_bundle_tree(path)
        subprocess.run(["defaults", "delete", bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        for cache_root in ("Library/Preferences", "Library/Caches", "Library/HTTPStorages"):
            target = home / cache_root / (f"{bundle_id}.plist" if cache_root == "Library/Preferences" else bundle_id)
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target, ignore_errors=True)
            elif target.exists() or target.is_symlink():
                target.unlink(missing_ok=True)
    subprocess.run(["tccutil", "reset", "All", LEGACY_BUNDLE_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run([LSREGISTER, "-gc"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    migrate_legacy_preview_data()


new_version = str(plistlib.loads((stage / "Contents/Info.plist").read_bytes())["CFBundleVersion"])
bundle_id = plistlib.loads((stage / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
if bundle_id != BUNDLE_ID:
    raise SystemExit(f"Expected bundle id {BUNDLE_ID}, got {bundle_id}")
if stage == installed.resolve() or installed.resolve() in stage.parents:
    raise SystemExit("Staged app must be separate from installed app")

subprocess.run(["codesign", "--verify", "--deep", "--strict", str(stage)], check=True)
current = subprocess.check_output([str(helper), "current"], text=True).strip()
if current.startswith(LEGACY_BUNDLE_ID) or not current:
    current = INPUT_MODE_ID

rollback = work / "rollback" / APP_NAME
moved = False
copied = False
try:
    subprocess.run([str(helper), "select", "com.apple.keylayout.ABC"], check=True)
    remove_legacy_preview_app()
    if installed.exists():
        stop_processes(str(installed) + "/")
    time.sleep(1)
    if installed.exists():
        rollback.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(installed), str(rollback))
        moved = True
    installed.parent.mkdir(parents=True, exist_ok=True)
    copied = True
    shutil.copytree(stage, installed, symlinks=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installed)], check=True)
    subprocess.run([str(installed / "Contents/MacOS/AIME"), "--install"], check=False)
    subprocess.run([str(helper), "register", str(installed), INPUT_MODE_ID], check=True)
except BaseException:
    if copied and installed.exists():
        shutil.rmtree(installed, ignore_errors=True)
    if moved and rollback.exists():
        shutil.move(str(rollback), str(installed))
        subprocess.run([str(helper), "register", str(installed), INPUT_MODE_ID], check=False)
    if current:
        subprocess.run([str(helper), "select", current], check=False)
    raise
finally:
    # Always remove rollback and staged copies and unregister them from LaunchServices so no duplicate exists.
    for extra in (rollback, stage):
        if extra.exists():
            unregister_bundle_tree(extra)
            shutil.rmtree(extra, ignore_errors=True)

installed_settings = installed / "Contents/Applications/AIME Settings.app"
for other in sorted({path for path in registered_copies(BUNDLE_ID) if path.resolve() != installed.resolve()}):
    unregister_bundle_tree(other)
for other in sorted({path for path in registered_copies("app.zool.aime.settings") if path.resolve() != installed_settings.resolve()}):
    subprocess.run([LSREGISTER, "-u", str(other)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run([LSREGISTER, "-f", str(installed_settings)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if current:
    subprocess.run([str(helper), "select", current], check=False)
# Stop any manually-launched AIME instance so imklaunchagent starts the input method on demand.
subprocess.run(["/usr/bin/pkill", "-x", "AIME"], check=False)
subprocess.run(["open", str(installed_settings)], check=True)
print(f"Installed {installed} (Build {new_version}); all temporary/old bundles removed.")
print("Active input source:", current)
