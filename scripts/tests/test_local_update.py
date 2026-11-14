#!/usr/bin/env python3
"""Public CLI tests. All repositories, hooks and installations are disposable."""
import json
import hashlib
import fcntl
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CLI = Path(__file__).resolve().parents[1] / "local-update.py"
HOOKS = ("verify-source", "build", "sign", "verify-app", "idle-gate", "launch")
FIXTURE_HOOK = '''import json, pathlib, shutil, sys
p = json.load(sys.stdin)
root = pathlib.Path(__file__).parent.parent
phase = pathlib.Path(__file__).stem
if (root / ("fail-" + phase)).exists():
    print("fixture deliberately fails", file=sys.stderr)
    sys.exit(9)
answer = {"ok": True}
if phase == "verify-source":
    assert (pathlib.Path(p["source_dir"]) / "voice.txt").read_text() == "custom voice\\n"
    answer["checks"] = ["host", "runtime", "settings", "vocabulary"]
elif phase == "build":
    shutil.copytree(root / "new.app", p["staged_app"], symlinks=True)
    shutil.copy(pathlib.Path(p["source_dir"]) / "upstream.txt", pathlib.Path(p["staged_app"]) / "upstream.txt")
elif phase == "verify-app":
    answer.update(identity_verified=True, entitlements_verified=True, licenses_verified=True, data_compatible=True)
    if p.get("purpose") == "reference" and (root / "unsigned-reference").exists():
        answer["identity_verified"] = False
elif phase == "idle-gate":
    if (root / "empty-gate").exists():
        print(json.dumps(answer))
        sys.exit(0)
    if (root / "busy").exists():
        answer = {"ok": False, "busy": True}
    elif p["action"] == "acquire":
        (root / "lease").write_text(p["operation_id"])
        answer.update(lease=p["operation_id"], idle=True, held=True)
    elif p["action"] == "validate":
        answer.update(held=(root / "lease").read_text() == p["lease"])
        if (root / "fail-exchange").exists():
            pathlib.Path(p["staged_app"]).parent.chmod(0o555)
    elif p["action"] == "quiesce":
        answer.update(held=True, idle=True)
    elif p["action"] == "release":
        if (root / "fail-release").exists():
            sys.exit(8)
        (root / "lease").unlink()
elif phase == "launch":
    import plistlib
    version = plistlib.loads((pathlib.Path(p["installed_app"]) / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
    answer["ready"] = not (version == "2" and (root / "fail-new-launch").exists())
print(json.dumps(answer))
'''


class LocalUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        self.git(self.upstream, "init", "-q")
        (self.upstream / "upstream.txt").write_text("original\n")
        self.base = self.commit(self.upstream, "base")
        self.git(self.upstream, "tag", "v1.0.0")
        self.source = self.root / "source"
        self.git(self.root, "clone", "-q", str(self.upstream), str(self.source))
        (self.source / "voice.txt").write_text("custom voice\n")
        self.baseline = self.commit(self.source, "voice")
        (self.upstream / "upstream.txt").write_text("stable update\n")
        self.stable = self.commit(self.upstream, "stable")
        self.git(self.upstream, "tag", "v1.1.0")
        (self.upstream / "upstream.txt").write_text("preview\n")
        self.preview = self.commit(self.upstream, "preview")
        self.git(self.upstream, "tag", "v2.0.0-beta.1")
        self.catalog = self.root / "releases.json"
        self.catalog.write_text(json.dumps([
            {"tag_name": "v2.0.0-beta.1", "draft": False, "prerelease": True},
            {"tag_name": "v1.1.0", "draft": False, "prerelease": False},
            {"tag_name": "v1.0.0", "draft": False, "prerelease": False},
        ]))
        self.config = self.root / "config.json"
        self.settings = {
            "schema_version": 1, "state_dir": str(self.root / "state"),
            "baseline": {"repository": str(self.source), "commit": self.baseline,
                         "upstream_commit": self.base, "protected_paths": ["voice.txt"]},
            "upstream": {"repository": str(self.upstream), "releases": str(self.catalog)},
        }
        self.save()

    def git(self, cwd, *args):
        env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                   GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *args], cwd=cwd, env=env, text=True).strip()

    def commit(self, cwd, message):
        self.git(cwd, "add", ".")
        self.git(cwd, "commit", "-qm", message)
        return self.git(cwd, "rev-parse", "HEAD")

    def save(self):
        self.config.write_text(json.dumps(self.settings))

    def install_fixture(self):
        self.installed = self.root / "Applications" / "AIME.app"
        for app, version in ((self.installed, "1"), (self.root / "new.app", "2")):
            for relative, identifier in ((".", "app.zool.inputmethod.aime"),
                    ("Contents/Applications/AIME Settings.app", "app.zool.aime.settings"),
                    ("Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voice")):
                contents = app / relative / "Contents"
                (contents / "MacOS").mkdir(parents=True)
                (contents / "MacOS/Fake").write_text("fixture-only executable")
                info = dict(CFBundleIdentifier=identifier, CFBundleVersion=version, CFBundleExecutable="Fake")
                if relative == ".":
                    mode = "app.zool.inputmethod.aime.hans"
                    info["ComponentInputModeDict"] = {"tsInputModeListKey": {mode: {"TISInputSourceID": mode}}}
                (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        hooks = self.root / "hooks"
        hooks.mkdir()
        hashes = {}
        for name in HOOKS:
            (hooks / (name + ".py")).write_text(FIXTURE_HOOK)
            hashes[name] = hashlib.sha256(FIXTURE_HOOK.encode()).hexdigest()
        self.settings.update(installed_app=str(self.installed), hooks_dir=str(hooks), hooks_sha256=hashes,
                             signing_identity="A" * 40)
        self.save()

    def installed_version(self):
        return plistlib.loads((self.installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"]

    def test_busy_host_blocks_install_even_after_successful_build(self):
        self.install_fixture()
        (self.root / "busy").touch()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "busy", result)
        self.assertEqual(self.installed_version(), "1")
        self.assertEqual(result["recovery"], "unchanged")

    def test_apply_installs_integrated_app_and_keeps_recoverable_previous_build(self):
        self.install_fixture()
        user_data = self.root / "user-dictionary.json"
        user_data.write_text('{"word":"我的词"}')
        result = self.cli("apply", "--upstream", self.stable)
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["phase"], "complete")
        self.assertEqual(self.installed_version(), "2")
        self.assertEqual((self.installed / "upstream.txt").read_text(), "stable update\n")
        self.assertTrue(result["rollback_build"])
        self.assertEqual(user_data.read_text(), '{"word":"我的词"}')
        self.assertFalse((self.root / "lease").exists())

    def test_failed_launch_restores_previous_app_automatically(self):
        self.install_fixture()
        (self.root / "fail-new-launch").touch()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["error"]["category"], "launch_failed")
        self.assertEqual(result["recovery"], "restored")
        self.assertEqual(self.installed_version(), "1")
        self.assertFalse((self.root / "lease").exists())

    def test_explicit_rollback_works_offline_without_touching_new_user_data(self):
        self.install_fixture()
        applied = self.cli("apply", "--upstream", self.stable)
        self.assertTrue(applied["ok"], applied)
        self.catalog.unlink()
        data = self.root / "learned-words"
        data.write_text("learned after update")
        result = self.cli("rollback", "--build", applied["rollback_build"])
        self.assertTrue(result["ok"], result)
        self.assertEqual(self.installed_version(), "1")
        self.assertEqual(data.read_text(), "learned after update")

    def test_second_update_continues_installed_integration_history(self):
        self.install_fixture()
        first = self.cli("apply", "--upstream", self.stable)
        checked = self.cli("check")
        self.assertFalse(checked["update_available"], checked)
        repeated = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(repeated["error"]["category"], "already_current")
        self.git(self.upstream, "checkout", "--detach", self.stable)
        (self.upstream / "upstream.txt").write_text("second stable update\n")
        next_commit = self.commit(self.upstream, "second stable")
        self.git(self.upstream, "tag", "v1.2.0")
        catalog = json.loads(self.catalog.read_text())
        catalog.append(dict(tag_name="v1.2.0", draft=False, prerelease=False))
        self.catalog.write_text(json.dumps(catalog))
        second = self.cli("apply", "--upstream", next_commit)
        self.assertTrue(second["ok"], second)
        self.assertEqual(second["baseline_commit"], first["integration_commit"])
        self.assertEqual((self.installed / "upstream.txt").read_text(), "second stable update\n")

    def test_build_cannot_change_input_source_identity(self):
        self.install_fixture()
        info_path = self.root / "new.app/Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["ComponentInputModeDict"] = {"tsInputModeListKey": {"wrong.mode": {"TISInputSourceID": "wrong.mode"}}}
        info_path.write_bytes(plistlib.dumps(info))
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "identity_mismatch", result)
        self.assertEqual(self.installed_version(), "1")

    def test_gate_release_failure_is_not_reported_as_success(self):
        self.install_fixture()
        (self.root / "fail-release").touch()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["error"]["category"], "idle_gate_failed")
        self.assertEqual(result["recovery"], "installed_gate_held")
        self.assertEqual(self.installed_version(), "2")

    def test_events_stream_ends_with_the_same_result_contract(self):
        self.install_fixture()
        process = subprocess.run([sys.executable, str(CLI), "apply", "--config", str(self.config),
                                  "--upstream", self.stable, "--json", "--events"],
                                 capture_output=True, text=True, timeout=30)
        self.assertEqual(process.returncode, 0, process.stderr)
        messages = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(messages[-1]["type"], "result")
        self.assertTrue(messages[-1]["ok"])
        phases = [item["phase"] for item in messages if item["type"] == "progress"]
        for phase in ("resolve", "merge", "build", "sign", "idle-gate", "install", "launch", "complete"):
            self.assertIn(phase, phases)
        self.assertLess(phases.index("idle-gate"), phases.index("install"))

    def test_missing_production_hooks_fail_closed(self):
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "missing_config")
        self.assertEqual(result["recovery"], "unchanged")

    def test_sign_failure_never_reaches_installation(self):
        self.install_fixture()
        (self.root / "fail-sign").touch()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "sign_failed")
        self.assertEqual(self.installed_version(), "1")
        self.assertFalse((self.root / "lease").exists())

    def test_exit_zero_without_held_lease_is_rejected(self):
        self.install_fixture()
        (self.root / "empty-gate").touch()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "invalid_gate_response")
        self.assertEqual(self.installed_version(), "1")

    def test_changed_trusted_hook_is_rejected(self):
        self.install_fixture()
        (self.root / "hooks/build.py").write_text("raise SystemExit('not trusted')")
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "untrusted_hook")
        self.assertEqual(self.installed_version(), "1")

    def test_uncommitted_protected_changes_block_integration(self):
        (self.source / "voice.txt").write_text("unsaved feature")
        result = self.cli("check")
        self.assertEqual(result["error"]["category"], "baseline_incomplete")
        self.assertEqual((self.source / "voice.txt").read_text(), "unsaved feature")

    def test_concurrent_operation_is_rejected(self):
        state = self.root / "state"
        state.mkdir()
        with (state / "update.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.cli("check")
        self.assertEqual(result["error"]["category"], "locked")

    def test_atomic_exchange_failure_keeps_previous_app(self):
        self.install_fixture()
        (self.root / "fail-exchange").touch()
        try:
            result = self.cli("apply", "--upstream", self.stable)
            self.assertEqual(result["error"]["category"], "install_failed", result)
            self.assertEqual(self.installed_version(), "1")
            self.assertEqual(result["recovery"], "unchanged")
        finally:
            for directory in self.installed.parent.glob(".aime-local-*"):
                directory.chmod(0o700)

    def test_moved_stable_tag_does_not_silently_change_pinned_request(self):
        self.install_fixture()
        pinned = self.cli("check")["upstream_commit"]
        self.git(self.upstream, "tag", "-f", "v1.1.0", self.preview)
        result = self.cli("apply", "--upstream", pinned)
        self.assertEqual(result["error"]["category"], "not_stable_release")
        self.assertEqual(self.installed_version(), "1")

    def test_check_distinguishes_release_availability_from_install_configuration(self):
        checked = self.cli("check")
        self.assertTrue(checked["ok"], checked)
        self.assertFalse(checked["installation"]["configured"])
        self.assertFalse(checked["installation"]["idle_checked"])
        self.assertEqual(checked["installation"]["error"]["category"], "missing_config")
        self.install_fixture()
        checked = self.cli("check")
        self.assertTrue(checked["installation"]["configured"])
        self.assertFalse(checked["installation"]["idle_checked"])
        self.assertFalse((self.root / "lease").exists())

    def test_interrupted_install_is_reported_as_uncertain_not_unchanged(self):
        self.install_fixture()
        state = self.root / "state"
        state.mkdir()
        (state / "pending.json").write_text('{}')
        result = self.cli("check")
        self.assertEqual(result["error"]["category"], "interrupted_operation")
        self.assertEqual(result["recovery"], "manual_required")

    def test_new_ui_can_discover_rollback_and_still_check_after_app_drift(self):
        self.install_fixture()
        applied = self.cli("apply", "--upstream", self.stable)
        checked = self.cli("check")
        self.assertEqual(checked["build"], applied["build"])
        self.assertEqual(checked["rollback_build"], applied["rollback_build"])
        (self.installed / "changed.txt").write_text("external change")
        checked = self.cli("check")
        self.assertTrue(checked["ok"], checked)
        self.assertFalse(checked["installation"]["configured"])
        self.assertEqual(checked["installation"]["error"]["category"], "app_changed")
        rejected = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(rejected["error"]["category"], "app_changed")

    def test_unsigned_reference_blocks_apply_but_not_release_check(self):
        self.install_fixture()
        (self.root / "unsigned-reference").touch()
        checked = self.cli("check")
        self.assertTrue(checked["ok"], checked)
        self.assertFalse(checked["installation"]["configured"])
        self.assertEqual(checked["installation"]["error"]["category"], "verification_failed")
        applied = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(applied["error"]["category"], "verification_failed")
        self.assertEqual(self.installed_version(), "1")

    def test_build_failure_keeps_installed_app_and_dirty_work(self):
        self.install_fixture()
        (self.root / "fail-build").touch()
        (self.source / "scratch.txt").write_text("do not overwrite")
        result = self.cli("apply", "--upstream", self.stable)
        self.assertEqual(result["error"]["category"], "build_failed", result)
        self.assertEqual(result["phase"], "build")
        self.assertEqual(self.installed_version(), "1")
        self.assertEqual((self.source / "scratch.txt").read_text(), "do not overwrite")

    def cli(self, command, *args):
        result = subprocess.run([sys.executable, str(CLI), command, "--config", str(self.config), "--json", *args],
                                capture_output=True, text=True, timeout=30)
        self.assertIn(result.returncode, (0, 2), result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, response["ok"], response)
        return response

    def test_check_pins_latest_stable_and_leaves_working_tree_untouched(self):
        (self.source / "scratch.txt").write_text("uncommitted work")
        result = self.cli("check")
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["version"], "v1.1.0")
        self.assertEqual(result["upstream_commit"], self.stable)
        self.assertEqual(self.git(self.source, "rev-parse", "HEAD"), self.baseline)
        self.assertEqual((self.source / "scratch.txt").read_text(), "uncommitted work")

    def test_merge_conflict_stops_in_staging_without_editing_source(self):
        (self.source / "upstream.txt").write_text("my protected customization\n")
        self.settings["baseline"]["commit"] = self.commit(self.source, "conflicting customization")
        self.save()
        result = self.cli("apply", "--upstream", self.stable)
        self.assertFalse(result["ok"], result)
        self.assertEqual(result["error"]["category"], "merge_conflict")
        self.assertEqual(result["error"]["conflicts"], ["upstream.txt"])
        self.assertEqual(result["recovery"], "unchanged")
        self.assertEqual((self.source / "upstream.txt").read_text(), "my protected customization\n")

    def test_apply_requires_a_pinned_stable_commit(self):
        for target in (None, "latest", self.preview):
            with self.subTest(target=target):
                result = self.cli("apply", *(["--upstream", target] if target else []))
                self.assertFalse(result["ok"], result)
                self.assertIn(result["error"]["category"], ("invalid_request", "not_stable_release"))

    def test_missing_config_is_machine_readable_and_does_not_guess(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(CLI), "check", "--json", "--config", str(Path(directory) / "missing.json")],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 2)
            response = json.loads(result.stdout)
            self.assertEqual(response["error"]["category"], "missing_config")
            self.assertEqual(response["recovery"], "unchanged")


if __name__ == "__main__":
    unittest.main()
