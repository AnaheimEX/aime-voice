#!/usr/bin/env python3
"""Explicit, local-only integration runner. See docs/local-update-usage.md."""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import uuid


class Failure(Exception):
    def __init__(self, category, message, **details):
        super().__init__(message)
        self.category, self.details = category, details


class Progress(dict):
    """One final JSON by default; optional phase-only NDJSON for the settings UI."""
    def __init__(self, events, **values):
        super().__init__(values)
        self.events = events
        self.emit()

    def emit(self):
        if self.events:
            fields = {key: self.get(key) for key in ("schema_version", "command", "phase", "version", "upstream_commit", "build", "recovery")}
            print(json.dumps(dict(fields, type="progress")), flush=True)

    def __setitem__(self, key, value):
        super().__setitem__(key, value)
        if key == "phase":
            self.emit()

    def update(self, **values):
        super().update(values)
        if "phase" in values:
            self.emit()


def require(condition, category, message, **details):
    if not condition:
        raise Failure(category, message, **details)


def full_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value)


def absolute(value):
    require(isinstance(value, str) and Path(value).is_absolute(), "invalid_config", "Paths must be explicit absolute paths.")
    return Path(value).resolve()


def git(directory, *arguments, check=True):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
               GIT_ASKPASS="/usr/bin/false", GIT_AUTHOR_NAME="AIME Local Integration",
               GIT_AUTHOR_EMAIL="local-integration@localhost", GIT_COMMITTER_NAME="AIME Local Integration",
               GIT_COMMITTER_EMAIL="local-integration@localhost")
    result = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=",
                             "-c", "protocol.ext.allow=never", *arguments], cwd=directory, env=env,
                            capture_output=True, text=True, timeout=180)
    if check and result.returncode:
        raise Failure("git_failed", "Git operation failed; raw output is withheld to avoid credential disclosure.")
    return result


def config_at(path, validate_baseline=True):
    require(path.is_file(), "missing_config", "Provide an explicit local integration configuration; no baseline is inferred.")
    config = json.loads(path.read_text())
    require(config.get("schema_version") == 1, "invalid_config", "Expected configuration schema_version 1.")
    baseline = config["baseline"]
    require(full_sha(baseline["commit"]) and full_sha(baseline["upstream_commit"]), "invalid_config", "Both baseline commits must be full SHA-1 values.")
    source = absolute(baseline["repository"])
    state = absolute(config["state_dir"])
    require(state != source and source not in state.parents and state not in source.parents,
            "invalid_config", "State and source directories must not overlap.")
    require(baseline.get("protected_paths"), "invalid_config", "Explicit protected source paths are required.")
    for relative in baseline["protected_paths"]:
        require(isinstance(relative, str) and not Path(relative).is_absolute() and ".." not in Path(relative).parts and not relative.startswith(":") and relative != ".",
                "invalid_config", "Protected paths must be relative source paths.")
        if validate_baseline:
            tracked = git(source, "ls-tree", "-r", baseline["commit"], "--", relative).stdout.strip()
            require(tracked, "baseline_incomplete", "Protected source is absent from the committed baseline.", path=relative)
            require(not git(source, "diff", baseline["commit"], "--", relative).stdout and
                    not git(source, "ls-files", "--others", "--", relative).stdout,
                    "baseline_incomplete", "Protected changes must be included in the explicit baseline.", path=relative)
    if validate_baseline:
        require(git(source, "merge-base", "--is-ancestor", baseline["upstream_commit"], baseline["commit"], check=False).returncode == 0,
                "invalid_baseline", "Upstream baseline must be an ancestor of the integration baseline.")
    upstream = config["upstream"]["repository"]
    require(isinstance(upstream, str) and (Path(upstream).is_absolute() or re.fullmatch(r"https://github.com/[\w.-]+/[\w.-]+(?:\.git)?", upstream)),
            "invalid_config", "Upstream must be a local repository or a public GitHub HTTPS URL without credentials.")
    return config, source, state


def release_catalog(config):
    location = config["upstream"]["releases"]
    if location.startswith("https://"):
        require(re.fullmatch(r"https://api.github.com/repos/[\w.-]+/[\w.-]+/releases(?:\?per_page=100)?", location),
                "invalid_config", "Only the public GitHub releases endpoint is supported.")
        # Public release metadata only; never use a credential manager or GitHub CLI login.
        request = urllib.request.Request(location, headers={"Accept": "application/vnd.github+json", "User-Agent": "AIME-LocalIntegration"})
        with urllib.request.urlopen(request, timeout=30) as response:
            catalog = json.load(response)
    else:
        catalog = json.loads(absolute(location).read_text())
    require(isinstance(catalog, list), "invalid_releases", "Expected a release catalog array.")
    releases = []
    for release in catalog:
        tag = release.get("tag_name", "")
        match = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
        if match and release.get("draft") is False and release.get("prerelease") is False:
            releases.append((tuple(map(int, match.groups())), tag))
    require(releases, "no_stable_release", "No explicitly non-draft, non-prerelease SemVer release is available.")
    return sorted(releases, reverse=True)


def prepare(config, source, state):
    operation = Path(tempfile.mkdtemp(prefix="operation-", dir=state))
    repository = operation / "source"
    repository.mkdir()
    git(repository, "init", "-q")
    git(repository, "fetch", "--no-tags", str(source), config["baseline"]["commit"])
    git(repository, "checkout", "--detach", config["baseline"]["commit"])
    return operation, repository


def resolve_release(config, repository, target=None):
    releases = release_catalog(config)
    for _, tag in releases:
        git(repository, "fetch", "--no-tags", config["upstream"]["repository"], "refs/tags/" + tag)
        commit = git(repository, "rev-parse", "FETCH_HEAD^{commit}").stdout.strip()
        if target is None or commit == target:
            require(git(repository, "merge-base", "--is-ancestor", config["baseline"]["upstream_commit"], commit, check=False).returncode == 0,
                    "upstream_diverged", "Stable release does not descend from the explicit upstream baseline.")
            return tag, commit
    raise Failure("not_stable_release", "The requested full commit is not a published stable release in the configured catalog.")


HOOKS = ("verify-source", "build", "sign", "verify-app", "idle-gate", "launch")
BUNDLES = ((".", "app.zool.inputmethod.aime.voicepreview"),
           ("Contents/Applications/AIME Settings.app", "app.zool.aime.voicepreview.settings"),
           ("Contents/XPCServices/AIME Voice.xpc", "app.zool.aime.voicepreview.service"))


def inspect_app(app):
    require(app.is_dir() and not app.is_symlink(), "invalid_app", "A complete non-symlink App is required.")
    versions = set()
    for relative, identifier in BUNDLES:
        bundle = app / relative
        info_path = bundle / "Contents/Info.plist"
        require(info_path.is_file() and app.resolve() in info_path.resolve().parents,
                "invalid_app", "All three App bundles must be inside staging.")
        info = plistlib.loads(info_path.read_bytes())
        if relative == ".":
            mode = "app.zool.inputmethod.aime.voicepreview.hans"
            modes = info.get("ComponentInputModeDict", {}).get("tsInputModeListKey", {})
            require(set(modes) == {mode} and modes[mode].get("TISInputSourceID") == mode,
                    "identity_mismatch", "Input source identity must remain the installed Voice Preview identity.")
        executable = info.get("CFBundleExecutable", "")
        require(info.get("CFBundleIdentifier") == identifier and executable and Path(executable).name == executable,
                "identity_mismatch", "App bundle identity or executable changed.")
        binary = bundle / "Contents/MacOS" / executable
        require(binary.is_file() and app.resolve() in binary.resolve().parents,
                "invalid_app", "Missing bundle executable.")
        versions.add(str(info.get("CFBundleVersion", "")))
    require(len(versions) == 1 and "" not in versions, "invalid_app", "All three bundles must share one build version.")
    return versions.pop()


def verify_app(config, context):
    inspect_app(Path(context["staged_app"]))
    answer = hook(config, "verify-app", context)
    require(all(answer.get(key) is True for key in ("identity_verified", "entitlements_verified", "licenses_verified", "data_compatible")),
            "verification_failed", "Signature, entitlements, licenses and data compatibility must be explicitly confirmed.")


def fingerprint(app):
    """Bind receipts to bundle contents, relative symlinks and permission bits."""
    digest = hashlib.sha256()
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        require(not path.is_symlink() or app.resolve() in path.resolve().parents,
                "invalid_app", "App symlink escapes the bundle.")
        stat = path.lstat()
        digest.update(json.dumps([relative, stat.st_mode], separators=(",", ":")).encode())
        if path.is_symlink():
            digest.update(os.readlink(path).encode())
        elif path.is_file():
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def exchange(first, second):
    """One kernel exchange; never fall back to two non-atomic renames."""
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        function = libc.renamex_np
        function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        status = function(os.fsencode(first), os.fsencode(second), 2)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        function = libc.renameat2
        function.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint)
        status = function(-100, os.fsencode(first), -100, os.fsencode(second), 2)
    else:
        raise Failure("atomic_exchange_unavailable", "Atomic directory exchange is required on this platform.")
    require(status == 0, "install_failed", "Atomic App exchange failed.", errno=ctypes.get_errno() if status else 0)


def install(config, state, context, result, provenance):
    installed = Path(context["installed_app"])
    previous_hash = fingerprint(installed)
    previous_version = inspect_app(installed)
    slot = Path(tempfile.mkdtemp(prefix=".aime-local-", dir=installed.parent)) / "AIME.app"
    shutil.copytree(context["staged_app"], slot, symlinks=True, copy_function=shutil.copy2)
    context = dict(context, staged_app=str(slot), runner_pid=os.getpid())
    verify_app(config, context)
    candidate_hash = fingerprint(slot)
    build = uuid.uuid4().hex
    rollback_build = uuid.uuid4().hex
    receipts = state / "builds"
    receipts.mkdir(exist_ok=True)
    current_file = state / "current.json"
    previous = json.loads(current_file.read_text()) if current_file.exists() else dict(
        source_dir=config["baseline"]["repository"], integration_commit=config["baseline"]["commit"],
        upstream_commit=config["baseline"]["upstream_commit"], version=None)
    rollback_build = previous.get("build", rollback_build)
    result.update(build=build, rollback_build=rollback_build)
    prior_receipt = dict(previous, build=rollback_build, app_path=str(slot), app_version=previous_version, digest=previous_hash)
    new_receipt = dict(provenance, build=build, rollback_build=rollback_build, app_path=str(installed),
                       app_version=inspect_app(slot), digest=candidate_hash)
    result["phase"] = "idle-gate"
    lease = hook(config, "idle-gate", context, action="acquire")
    require(lease.get("idle") is True and lease.get("held") is True and isinstance(lease.get("lease"), str) and lease["lease"],
            "invalid_gate_response", "Host must hold an idle lease; a point-in-time idle check is insufficient.")
    swapped = False
    try:
        held = hook(config, "idle-gate", context, action="validate", lease=lease["lease"])
        require(held.get("held") is True, "busy", "Installation lease expired or was revoked.")
        require(fingerprint(installed) == previous_hash and fingerprint(slot) == candidate_hash,
                "app_changed", "App contents changed during installation preparation.")
        result["phase"] = "install"
        write_json(receipts / (rollback_build + ".json"), prior_receipt)
        write_json(state / "pending.json", dict(previous=prior_receipt, candidate=new_receipt))
        exchange(slot, installed)
        swapped = True
        result["recovery"] = "previous_available"
        result["phase"] = "launch"
        launched = hook(config, "launch", context, action="start", lease=lease["lease"])
        require(launched.get("ready") is True, "launch_failed", "New App did not confirm basic readiness.")
        write_json(receipts / (build + ".json"), new_receipt)
        write_json(current_file, new_receipt)
        (state / "pending.json").unlink()
        result.update(ok=True, phase="complete")
    except (Failure, OSError, ValueError) as original:
        if swapped:
            result["phase"] = "recover"
            try:
                quiescent = hook(config, "idle-gate", context, action="quiesce", lease=lease["lease"])
                require(quiescent.get("held") is True and quiescent.get("idle") is True,
                        "busy", "Cannot safely restore while the new App accepts input.")
                exchange(slot, installed)
                prior_receipt["app_path"] = str(installed)
                write_json(receipts / (rollback_build + ".json"), prior_receipt)
                write_json(current_file, prior_receipt)
                result["recovery"] = "restored_not_ready"
                restored = hook(config, "launch", context, action="restore", lease=lease["lease"])
                require(restored.get("ready") is True, "recovery_failed", "Previous App was restored but did not confirm readiness.")
                (state / "pending.json").unlink()
                result["recovery"] = "restored"
            except (Failure, OSError, ValueError):
                if result["recovery"] != "restored_not_ready":
                    result["recovery"] = "manual_required"
                raise Failure("recovery_failed", "Automatic recovery did not complete; retained journal and App copies require inspection.") from original
        else:
            (state / "pending.json").unlink(missing_ok=True)
        raise
    finally:
        try:
            hook(config, "idle-gate", context, action="release", lease=lease["lease"])
        except Failure:
            if result["ok"]:
                result.update(ok=False, phase="release", recovery="installed_gate_held")
            else:
                result["gate_release_failed"] = True
            raise


def installation_config(config, source, state):
    require(all(key in config for key in ("installed_app", "hooks_dir", "hooks_sha256", "signing_identity")),
            "missing_config", "Installation requires an explicit App, signing identity and six trusted hooks.")
    installed = absolute(config["installed_app"])
    require(installed.suffix == ".app" and installed.is_dir() and not Path(config["installed_app"]).is_symlink(),
            "invalid_config", "Installed App must be an existing, non-symlink .app directory.")
    for other in (source, state):
        require(installed != other and installed not in other.parents and other not in installed.parents,
                "invalid_config", "App, state and source must not overlap.")
    require(re.fullmatch(r"[0-9A-Fa-f]{40}", config["signing_identity"]), "invalid_config", "An explicit certificate fingerprint is required; no identity lookup.")
    for name in HOOKS:
        trusted_hook(config, name)
    return installed


def trusted_hook(config, name):
    directory = absolute(config["hooks_dir"])
    script = directory / (name + ".py")
    require(script.is_file() and not script.is_symlink() and script.resolve().parent == directory,
            "missing_hook", "Missing trusted hook: " + name)
    require(hashlib.sha256(script.read_bytes()).hexdigest() == config["hooks_sha256"].get(name),
            "untrusted_hook", "Hook contents differ from the explicitly trusted SHA-256: " + name)
    return script


def hook(config, name, context, **extra):
    script = trusted_hook(config, name)
    request = dict(context, schema_version=1, **extra)
    # Fixed interpreter, fixed filenames, JSON stdin, no shell or configuration-defined argv.
    try:
        process = subprocess.run([sys.executable, "-I", str(script)], input=json.dumps(request),
                                 capture_output=True, text=True, cwd=script.parent, timeout=1800 if name == "build" else 180)
    except subprocess.TimeoutExpired:
        raise Failure(name.replace("-", "_") + "_failed", "Trusted hook timed out: " + name)
    require(process.returncode == 0, name.replace("-", "_") + "_failed", "Trusted hook failed: " + name)
    try:
        answer = json.loads(process.stdout)
    except ValueError:
        raise Failure("invalid_hook_response", "Trusted hook must return one JSON object: " + name)
    require(isinstance(answer, dict), "invalid_hook_response", "Trusted hook must return one JSON object.")
    if name == "idle-gate" and answer.get("busy") is True:
        raise Failure("busy", "Host did not grant an idle installation window.")
    require(answer.get("ok") is True, name.replace("-", "_") + "_failed", "Trusted hook did not confirm success: " + name)
    return answer


def verify_current(config, current):
    require(fingerprint(absolute(config["installed_app"])) == current["digest"], "app_changed",
            "Installed App differs from the last integration receipt; explicitly rebaseline before updating.")


def execute(args, result, scratch):
    require(args.command != "apply" or full_sha(args.upstream), "invalid_request", "apply requires --upstream with a full stable commit SHA.")
    require(args.command != "rollback" or args.build, "invalid_request", "rollback requires --build.")
    config, source, state = config_at(args.config, validate_baseline=args.command != "rollback")
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (state / "update.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("locked", "Another local integration operation holds the lock.")
        if (state / "pending.json").exists():
            result["recovery"] = "manual_required"
            raise Failure("interrupted_operation", "An interrupted installation journal requires inspection before another update.")
        current_path = state / "current.json"
        current = json.loads(current_path.read_text()) if current_path.exists() else None
        if current and args.command == "apply":
            verify_current(config, current)
        if current and args.command == "check":
            result.update(build=current["build"], rollback_build=current.get("rollback_build"))
        if args.command == "rollback":
            require(re.fullmatch(r"[a-f0-9]{32}", args.build), "invalid_request", "--build must be an issued local build identifier.")
            installed = installation_config(config, source, state)
            receipt_path = state / "builds" / (args.build + ".json")
            require(receipt_path.is_file(), "unknown_build", "No verified receipt exists for the requested build.")
            receipt = json.loads(receipt_path.read_text())
            candidate = absolute(receipt["app_path"])
            require(candidate != installed and candidate.parent.parent == installed.parent and candidate.parent.name.startswith(".aime-local-"),
                    "invalid_receipt", "Rollback must select a retained local App copy.")
            require(candidate.is_dir() and fingerprint(candidate) == receipt["digest"],
                    "artifact_changed", "Retained App no longer matches its verified receipt.")
            context = dict(operation_id="rollback-" + uuid.uuid4().hex, source_dir=receipt["source_dir"],
                           staged_app=str(candidate), installed_app=str(installed), signing_identity=config["signing_identity"],
                           upstream_commit=receipt["upstream_commit"], version=receipt["version"])
            result.update(version=receipt["version"], upstream_commit=receipt["upstream_commit"], phase="verify-app")
            verify_app(config, context)
            install(config, state, context, result, receipt)
            return
        if current:
            source = absolute(current["source_dir"])
            config = dict(config, baseline=dict(config["baseline"], commit=current["integration_commit"],
                                               upstream_commit=current["upstream_commit"]))
        result["phase"] = "resolve"
        operation, repository = prepare(config, source, state)
        if args.command == "check":
            # A check only needs the checkout to resolve the release; keep nothing behind.
            scratch.append(operation)
        else:
            result["operation_dir"] = str(operation)
        version, commit = resolve_release(config, repository, args.upstream)
        result.update(version=version, upstream_commit=commit, phase="checked", baseline_commit=config["baseline"]["commit"],
                      update_available=commit != config["baseline"]["upstream_commit"])
        if args.command == "check":
            try:
                installation_config(config, source, state)
                if current:
                    verify_current(config, current)
                verify_app(config, dict(purpose="reference", operation_id=operation.name,
                    source_dir=str(repository), staged_app=config["installed_app"], installed_app=config["installed_app"],
                    signing_identity=config["signing_identity"], upstream_commit=commit, version=version))
                result["installation"] = dict(configured=True, idle_checked=False, error=None)
            except (Failure, KeyError, ValueError, TypeError, OSError) as error:
                result["installation"] = dict(configured=False, idle_checked=False, error=dict(
                    category=error.category if isinstance(error, Failure) else "invalid_config",
                    message=str(error) if isinstance(error, Failure) else "Installation configuration is incomplete."))
            result["ok"] = True
            return
        require(result["update_available"], "already_current", "Requested upstream commit is already integrated.")
        result["phase"] = "merge"
        merge = git(repository, "merge", "--no-edit", "--no-ff", commit, check=False)
        if merge.returncode:
            conflicts = git(repository, "diff", "--name-only", "--diff-filter=U").stdout.splitlines()
            raise Failure("merge_conflict" if conflicts else "merge_failed", "Integration stopped; source and installed App were not changed.", conflicts=conflicts)
        installed = installation_config(config, source, state)
        context = dict(operation_id=operation.name, source_dir=str(repository),
                       staged_app=str(repository / "build/LocalIntegration/AIME Voice Preview.app"),
                       installed_app=str(installed), signing_identity=config["signing_identity"],
                       upstream_commit=commit, version=version)
        result["phase"] = "verify-reference"
        verify_app(config, dict(context, staged_app=str(installed), purpose="reference"))
        result["phase"] = "verify-source"
        answer = hook(config, "verify-source", context)
        require(set(answer.get("checks", [])) >= {"host", "runtime", "settings", "vocabulary"},
                "verification_failed", "Source hook must confirm all four agreed behavior checks.")
        result["phase"] = "build"
        hook(config, "build", context)
        inspect_app(Path(context["staged_app"]))
        inspect_app(installed)
        result["phase"] = "sign"
        hook(config, "sign", context)
        result["phase"] = "verify-app"
        verify_app(config, context)
        provenance = dict(version=version, upstream_commit=commit, source_dir=str(repository),
                          integration_commit=git(repository, "rev-parse", "HEAD").stdout.strip())
        result["integration_commit"] = provenance["integration_commit"]
        install(config, state, context, result, provenance)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply", "rollback"))
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / ".local-update.json")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--events", action="store_true", help="Emit NDJSON progress followed by one final result (implies --json).")
    parser.add_argument("--upstream")
    parser.add_argument("--build")
    args = parser.parse_args()
    result = Progress(args.events, schema_version=1, command=args.command, ok=False, phase="config", version=None,
                      upstream_commit=None, build=None, rollback_build=None, recovery="unchanged", error=None)
    scratch = []
    try:
        execute(args, result, scratch)
    except Failure as error:
        result["ok"] = False
        result["error"] = dict(category=error.category, message=str(error), **error.details)
    except (KeyError, ValueError, TypeError, AttributeError):
        result["ok"] = False
        result["error"] = dict(category="invalid_config", message="Missing or malformed configuration, catalog or hook response.")
    except (OSError, subprocess.TimeoutExpired):
        result["ok"] = False
        result["error"] = dict(category="operation_failed", message="Filesystem, network or command operation failed.")
    finally:
        for directory in scratch:
            shutil.rmtree(directory, ignore_errors=True)
    if args.events:
        result["type"] = "result"
    print(json.dumps(result, ensure_ascii=False) if args.json or args.events else result, flush=True)
    return 0 if result["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
