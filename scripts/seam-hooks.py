#!/usr/bin/env python3
"""
Deterministic, idempotent manager for the thin local seam hooks in upstream AIME files.

Subcommands:
  check [--against <git-ref>]     Verify all hooks are applied (and stripping matches <git-ref>)
  check-upstream [<git-ref>]      Verify all hooks can be cleanly applied onto <git-ref> in memory
  apply [file ...]                Idempotently inject local hooks into upstream files
  strip [file ...]                Idempotently remove local hooks, restoring pure upstream files
  reapply-from <git-ref> [file...] Take pure upstream file(s) from <git-ref> and apply hooks
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Hook:
    name: str
    upstream: str
    hooked: str
    hooked_regex: str | None = None
    upstream_repl: str | None = None


FILE_HOOKS: dict[str, tuple[Hook, ...]] = {
    "Apps/AIME/AIMEInputController.swift": (
        Hook(
            name="import AIMEVoiceHost",
            upstream="import AIMECore\nimport AIMEPanel\n",
            hooked="import AIMECore\nimport AIMEVoiceHost\nimport AIMEPanel\n",
        ),
        Hook(
            name="voiceOwner property",
            upstream="    var polish: PolishSession?\n",
            hooked="    var polish: PolishSession?\n    let voiceOwner = InputOwner()\n",
        ),
        Hook(
            name="activate voiceFeature",
            upstream=r"(    private func activate\(client: \(any IMKTextInput\)\?\) \{\n(?:(?!    \}\n).*\n)+?)(    \}\n)",
            hooked=r"\1        engine.voiceFeature.activate(voiceOwner)\n\2",
            hooked_regex=r"(    private func activate\(client: \(any IMKTextInput\)\?\) \{\n(?:(?!    \}\n).*\n)+?)        engine\.voiceFeature\.activate\(voiceOwner\)\n(    \}\n)",
            upstream_repl=r"\1\2",
        ),
        Hook(
            name="deactivate voiceFeature",
            upstream=(
                "            this.cancelPolish()\n"
                "            this.commitPending(client)\n"
            ),
            hooked=(
                "            this.cancelPolish()\n"
                "            this.engine.voiceFeature.deactivate(this.voiceOwner)\n"
                "            this.commitPending(client)\n"
            ),
        ),
        Hook(
            name="recognizedEvents keyUp",
            upstream="        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)\n",
            hooked="        Int(NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged]).rawValue)\n",
        ),
        Hook(
            name="handle voiceFeature event",
            upstream=(
                "    private func handle(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {\n"
                "        // Event type and session state only — never the characters typed.\n"
                "        engine.activeController = self\n"
                "        guard let session = ensureSession() else {\n"
            ),
            hooked=(
                "    private func handle(_ event: NSEvent, client: (any IMKTextInput)?) -> Bool {\n"
                "        // Event type and session state only — never the characters typed.\n"
                "        engine.activeController = self\n"
                "        if engine.voiceFeature.handle(event, owner: voiceOwner) == .consumed {\n"
                "            liveSession?.cancelModifierTap()\n"
                "            return true\n"
                "        }\n"
                "        guard let session = ensureSession() else {\n"
            ),
        ),
    ),
    "Apps/AIME/AppDelegate.swift": (
        Hook(
            name="shutdown voiceFeature",
            upstream=(
                "    func applicationWillTerminate(_ notification: Notification) {\n"
                "        RimeKitShutdown.finalize()\n"
                "    }\n"
            ),
            hooked=(
                "    func applicationWillTerminate(_ notification: Notification) {\n"
                "        InputEngine.shared.voiceFeature.shutdown()\n"
                "        RimeKitShutdown.finalize()\n"
                "    }\n"
            ),
        ),
    ),
    "Apps/AIME/InputEngine.swift": (
        Hook(
            name="import AIMEVoiceHost",
            upstream="import AIMECore\nimport AIMEPanel\n",
            hooked="import AIMECore\nimport AIMEVoiceHost\nimport AIMEPanel\n",
        ),
        Hook(
            name="voiceFeature lazy property",
            upstream="    let usage = UsageRecorder()\n",
            hooked=(
                "    let usage = UsageRecorder()\n"
                "    lazy var voiceFeature = VoiceFeature(host: LocalVoiceAdapter(engine: self))\n"
            ),
        ),
        Hook(
            name="start touch voiceFeature",
            upstream="    func start() {\n        let fm = FileManager.default\n",
            hooked="    func start() {\n        _ = voiceFeature\n        let fm = FileManager.default\n",
        ),
    ),
    "Apps/AIMESettings/Model/DeployService.swift": (
        Hook(
            name="Locations.inputMethodBundleID",
            upstream='    static let inputMethodBundleID = "app.zool.inputmethod.aime"\n',
            hooked="    static let inputMethodBundleID = LocalBuildInfo.inputMethodBundleID\n",
        ),
    ),
    "Apps/AIMESettings/Model/SettingsModel.swift": (
        Hook(
            name="inputSourceState bundle & mode IDs",
            upstream=(
                '        guard let mode = enabled("app.zool.inputmethod.aime.hans") else { return .missing }\n'
                "        guard mode else { return .notAdded }\n"
                '        return enabled("app.zool.inputmethod.aime") == false ? .needsRelogin : .ready\n'
            ),
            hooked=(
                "        guard let mode = enabled(LocalBuildInfo.inputModeID) else { return .missing }\n"
                "        guard mode else { return .notAdded }\n"
                "        return enabled(LocalBuildInfo.inputMethodBundleID) == false ? .needsRelogin : .ready\n"
            ),
        ),
    ),
    "Apps/AIMESettings/Views/OverviewView.swift": (
        Hook(
            name="VersionFooter.updateControls",
            upstream=(
                "    @ViewBuilder private var updateControls: some View {\n"
                '        Toggle("自动检查更新", isOn: Binding(get: { model.updateState.autoCheck }, set: { model.setAutoUpdate($0) }))\n'
                "            .toggleStyle(.checkbox).font(.caption)\n"
                '            .help("每天请求一次 get.zool.app 上公开的版本清单，不发送任何输入内容")\n'
                '        Toggle("接收测试版", isOn: Binding(get: { model.updateState.receiveBeta }, set: { model.setReceiveBeta($0) }))\n'
                "            .toggleStyle(.checkbox).font(.caption)\n"
                '            .help("开启后检查测试版与正式版；关闭后只检查正式版")\n'
                "        Button {\n"
                "            Task { await model.checkForUpdates(userInitiated: true) }\n"
                "        } label: {\n"
                '            if model.updateChecking { ProgressView().controlSize(.small) } else { Text("检查更新") }\n'
                "        }\n"
                "        .controlSize(.small)\n"
                "        .disabled(model.updateChecking)\n"
                "    }\n"
            ),
            hooked=(
                "    @ViewBuilder private var updateControls: some View {\n"
                "        if LocalIntegrationControls.replacesUpdater { LocalIntegrationControls() } else {\n"
                '        Toggle("自动检查更新", isOn: Binding(get: { model.updateState.autoCheck }, set: { model.setAutoUpdate($0) }))\n'
                "            .toggleStyle(.checkbox).font(.caption)\n"
                '            .help("每天请求一次 get.zool.app 上公开的版本清单，不发送任何输入内容")\n'
                '        Toggle("接收测试版", isOn: Binding(get: { model.updateState.receiveBeta }, set: { model.setReceiveBeta($0) }))\n'
                "            .toggleStyle(.checkbox).font(.caption)\n"
                '            .help("开启后检查测试版与正式版；关闭后只检查正式版")\n'
                "        Button {\n"
                "            Task { await model.checkForUpdates(userInitiated: true) }\n"
                "        } label: {\n"
                '            if model.updateChecking { ProgressView().controlSize(.small) } else { Text("检查更新") }\n'
                "        }\n"
                "        .controlSize(.small)\n"
                "        .disabled(model.updateChecking)\n"
                "        }\n"
                "    }\n"
            ),
        ),
    ),
    "Apps/AIMESettings/Views/RootView.swift": (
        Hook(
            name="import AIMEVoiceSettings",
            upstream="import SwiftUI\n\nenum Pane:",
            hooked="import AIMEVoiceSettings\nimport SwiftUI\n\nenum Pane:",
        ),
        Hook(
            name="Pane.voice case",
            upstream=", stats, ai, advanced,",
            hooked=", stats, ai, voice, advanced,",
        ),
        Hook(
            name="Pane.voice title",
            upstream='        case .ai: "AI 助手"\n',
            hooked='        case .ai: "AI 助手"\n        case .voice: "语音输入"\n',
        ),
        Hook(
            name="Pane.voice symbol",
            upstream='        case .ai: "wand.and.sparkles"\n',
            hooked='        case .ai: "wand.and.sparkles"\n        case .voice: "mic"\n',
        ),
        Hook(
            name="Pane.sections voice entry",
            upstream='        ("智能", [.ai, .stats]),\n',
            hooked='        ("智能", [.ai, .voice, .stats]),\n',
        ),
        Hook(
            name="RootView.detail voice pane",
            upstream="        case .ai: AIAssistantView()\n",
            hooked=(
                "        case .ai: AIAssistantView()\n"
                "        case .voice: VoiceSettingsPane(style: VoiceSettingsStyle(\n"
                "                accent: Theme.accent, canvas: Theme.canvas, card: Theme.card,\n"
                "                cardBorder: Theme.cardBorder, warning: Theme.warning, success: Theme.success))\n"
            ),
        ),
    ),
    "Packages/AIMEKit/Sources/AIMECore/AIMEPaths.swift": (
        Hook(
            name="AIMEPaths.standard dataFolderName",
            upstream=(
                "        return AIMEPaths(\n"
                '            userDataDir: library.appendingPathComponent("AIME/Rime", isDirectory: true),\n'
                '            logDir: library.appendingPathComponent("Logs/AIME", isDirectory: true)\n'
                "        )\n"
            ),
            hooked=(
                "        return AIMEPaths(\n"
                '            userDataDir: library.appendingPathComponent("\\(LocalBuildInfo.dataFolderName)/Rime", isDirectory: true),\n'
                '            logDir: library.appendingPathComponent("Logs/\\(LocalBuildInfo.dataFolderName)", isDirectory: true)\n'
                "        )\n"
            ),
        ),
    ),
    "Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift": (
        Hook(
            name="SubscriptionManager.rebuild hook",
            upstream=(
                "                }\n"
                "            }\n"
                "        }\n"
                "        return entries.count\n"
                "    }\n"
            ),
            hooked=(
                "                }\n"
                "            }\n"
                "        }\n"
                "        try LocalVocabularyCustomization.afterRebuild(paths: paths, schemas: schemas)\n"
                "        return entries.count\n"
                "    }\n"
            ),
        ),
        Hook(
            name="SubscriptionManager.tableSignature hook",
            upstream=(
                '        for item in items.sorted(by: { $0.id < $1.id }) { parts.append("\\(item.id)=\\(digest(cacheURL(item.id)))") }\n'
                '        return parts.joined(separator: "|")\n'
            ),
            hooked=(
                '        for item in items.sorted(by: { $0.id < $1.id }) { parts.append("\\(item.id)=\\(digest(cacheURL(item.id)))") }\n'
                "        if let local = LocalVocabularyCustomization.signaturePart(paths: paths, schemas: schemas) { parts.append(local) }\n"
                '        return parts.joined(separator: "|")\n'
            ),
        ),
    ),
}


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parent.parent


def is_hook_present(hook: Hook, text: str) -> int:
    if hook.hooked_regex:
        return len(re.findall(hook.hooked_regex, text))
    return text.count(hook.hooked)


def apply_hooks_to_text(rel_path: str, text: str) -> str:
    hooks = FILE_HOOKS.get(rel_path)
    if not hooks:
        raise ValueError(f"unknown seam hook file: {rel_path}")
    for hook in hooks:
        present = is_hook_present(hook, text)
        if present:
            if present != 1:
                raise RuntimeError(f"{rel_path}: hook '{hook.name}' appears multiple times")
            continue
        if hook.hooked_regex:
            matches = len(re.findall(hook.upstream, text))
            if matches != 1:
                raise RuntimeError(
                    f"{rel_path}: cannot apply hook '{hook.name}' (anchor matched {matches} times)"
                )
            text = re.sub(hook.upstream, hook.hooked, text, count=1)
        else:
            count = text.count(hook.upstream)
            if count != 1:
                raise RuntimeError(
                    f"{rel_path}: cannot apply hook '{hook.name}' (anchor matched {count} times)"
                )
            text = text.replace(hook.upstream, hook.hooked, 1)
    return text


def strip_hooks_from_text(rel_path: str, text: str) -> str:
    hooks = FILE_HOOKS.get(rel_path)
    if not hooks:
        raise ValueError(f"unknown seam hook file: {rel_path}")
    for hook in reversed(hooks):
        present = is_hook_present(hook, text)
        if present:
            if present != 1:
                raise RuntimeError(f"{rel_path}: hook '{hook.name}' appears multiple times")
            if hook.hooked_regex:
                text = re.sub(hook.hooked_regex, hook.upstream_repl or "", text, count=1)
            else:
                text = text.replace(hook.hooked, hook.upstream, 1)
            continue
        if hook.hooked_regex:
            if not re.search(hook.upstream, text):
                raise RuntimeError(
                    f"{rel_path}: neither hooked nor upstream pattern found for '{hook.name}'"
                )
        elif hook.upstream not in text:
            raise RuntimeError(
                f"{rel_path}: neither hooked nor upstream pattern found for '{hook.name}'"
            )
    return text


def git_show(root: pathlib.Path, ref: str, rel_path: str) -> str:
    proc = subprocess.run(
        ["git", "show", f"{ref}:{rel_path}"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git show {ref}:{rel_path} failed: {proc.stderr.strip()}")
    return proc.stdout


def default_base_ref(root: pathlib.Path) -> str | None:
    merge_head = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if merge_head.returncode == 0 and merge_head.stdout.strip():
        return merge_head.stdout.strip()
    mb = subprocess.run(
        ["git", "merge-base", "HEAD", "origin/main"],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if mb.returncode == 0 and mb.stdout.strip():
        return mb.stdout.strip()
    return None


def resolve_targets(files: list[str]) -> list[str]:
    if not files:
        return list(FILE_HOOKS.keys())
    for f in files:
        if f not in FILE_HOOKS:
            raise ValueError(f"file is not in the seam hook list: {f}")
    return files


def cmd_apply(root: pathlib.Path, files: list[str]) -> int:
    for rel_path in resolve_targets(files):
        full_path = root / rel_path
        original = full_path.read_text(encoding="utf-8")
        updated = apply_hooks_to_text(rel_path, original)
        if updated != original:
            full_path.write_text(updated, encoding="utf-8")
    return 0


def cmd_strip(root: pathlib.Path, files: list[str]) -> int:
    for rel_path in resolve_targets(files):
        full_path = root / rel_path
        original = full_path.read_text(encoding="utf-8")
        updated = strip_hooks_from_text(rel_path, original)
        if updated != original:
            full_path.write_text(updated, encoding="utf-8")
    return 0


def cmd_reapply_from(root: pathlib.Path, ref: str, files: list[str]) -> int:
    for rel_path in resolve_targets(files):
        upstream_text = git_show(root, ref, rel_path)
        hooked_text = apply_hooks_to_text(rel_path, upstream_text)
        (root / rel_path).write_text(hooked_text, encoding="utf-8")
    return 0


def cmd_check(root: pathlib.Path, against_ref: str | None) -> int:
    ref = against_ref or default_base_ref(root)
    for rel_path, hooks in FILE_HOOKS.items():
        full_path = root / rel_path
        if not full_path.is_file():
            raise RuntimeError(f"missing hooked file: {rel_path}")
        text = full_path.read_text(encoding="utf-8")
        for hook in hooks:
            if is_hook_present(hook, text) != 1:
                raise RuntimeError(f"{rel_path}: missing or duplicate hook '{hook.name}'")
        stripped = strip_hooks_from_text(rel_path, text)
        if ref:
            upstream_text = git_show(root, ref, rel_path)
            if stripped != upstream_text:
                raise RuntimeError(
                    f"{rel_path}: unhooked content differs from {ref} outside registered hooks"
                )
    print("seam-hooks: ok")
    return 0


def cmd_check_upstream(root: pathlib.Path, ref: str) -> int:
    for rel_path in FILE_HOOKS:
        upstream_text = git_show(root, ref, rel_path)
        hooked_text = apply_hooks_to_text(rel_path, upstream_text)
        restripped = strip_hooks_from_text(rel_path, hooked_text)
        if restripped != upstream_text:
            raise RuntimeError(f"{rel_path}: roundtrip strip/apply mismatch on {ref}")
    print(f"seam-hooks: all {len(FILE_HOOKS)} files cleanly applicable onto {ref}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command")

    p_check = sub.add_parser("check", help="Verify all hooks are applied and match upstream")
    p_check.add_argument("--against", help="Git ref to compare stripped files against")

    p_check_up = sub.add_parser(
        "check-upstream", help="Verify hooks apply cleanly in memory onto a git ref"
    )
    p_check_up.add_argument("ref", nargs="?", default="origin/main")

    p_apply = sub.add_parser("apply", help="Idempotently apply hooks to working tree files")
    p_apply.add_argument("files", nargs="*")

    p_strip = sub.add_parser("strip", help="Idempotently strip hooks from working tree files")
    p_strip.add_argument("files", nargs="*")

    p_reapply = sub.add_parser(
        "reapply-from", help="Take pure upstream file(s) from <ref> and apply hooks"
    )
    p_reapply.add_argument("ref")
    p_reapply.add_argument("files", nargs="*")

    args = parser.parse_args(argv)
    root = repo_root()
    cmd = args.command or "check"

    try:
        if cmd == "check":
            return cmd_check(root, getattr(args, "against", None))
        if cmd == "check-upstream":
            return cmd_check_upstream(root, args.ref)
        if cmd == "apply":
            return cmd_apply(root, args.files)
        if cmd == "strip":
            return cmd_strip(root, args.files)
        if cmd == "reapply-from":
            return cmd_reapply_from(root, args.ref, args.files)
    except Exception as exc:
        print(f"seam-hooks: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
