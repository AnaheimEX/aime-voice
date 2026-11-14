import AppKit
import SwiftUI

/// Suppresses the official in-app pkg updater on local voice builds and directs
/// updates through the local sync/build workflow (with optional `.local-update.json` runner).
struct LocalIntegrationControls: View {
    /// Set by project.local.yml; replaces the official updater controls in the version footer.
    static var replacesUpdater: Bool { Bundle.main.object(forInfoDictionaryKey: "AIMELocalIntegration") as? Bool == true }

    private static let dailyCLICommand = "scripts/sync-upstream.sh && bash scripts/local-preview-build64/build.sh <build> --install"

    @AppStorage("localIntegrationRepository") private var repository = ""
    @State private var showCLIRunner = false
    @State private var running = false
    @State private var notice = ""
    @State private var installationConfigured = false
    @State private var upstream: String?
    @State private var rollbackBuild: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("本机语音集成 · 已接管更新")
                    .font(.caption.weight(.semibold))
                    .help("本机构建包含独立语音模块；已禁用官网自动安装包，避免覆盖丢失语音服务。日常请通过命令行同步上游并重建安装。")
                Button("复制更新命令", action: copyCLICommand)
                Button(showCLIRunner ? "收起配置" : "高级配置…") { showCLIRunner.toggle() }
            }
            .controlSize(.small)
            if showCLIRunner {
                HStack(spacing: 12) {
                    Button(repository.isEmpty ? "选择源码目录…" : "更换目录…", action: chooseRepository)
                    Button("检查上游") { start("check") }.disabled(repository.isEmpty || running)
                    Button("同步重建") { start("apply", argument: upstream) }
                        .disabled(upstream == nil || !installationConfigured || running)
                    Button("回退上版") { start("rollback", argument: rollbackBuild) }
                        .disabled(rollbackBuild == nil || !installationConfigured || running)
                    if running { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(Theme.secondaryText) }
        }
        .onAppear {
            if hasExplicitCLIConfig { showCLIRunner = true }
        }
    }

    private var hasExplicitCLIConfig: Bool {
        guard !repository.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: repository).appendingPathComponent(".local-update.json").path)
    }

    private func copyCLICommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.dailyCLICommand, forType: .string)
        notice = "已复制命令行更新指令（请在源码根目录运行，并将 <build> 替换为递增构建号）"
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择已配置 .local-update.json 的 AIME 源码目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/local-update.py").path) else {
            notice = "该目录没有本机更新命令"; return
        }
        repository = url.path
        upstream = nil; rollbackBuild = nil; installationConfigured = false
        showCLIRunner = true
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".local-update.json").path) {
            notice = "先检查上游；缺少集成基线或安全安装条件时会停止"
        } else {
            notice = "该目录尚未配置 .local-update.json；日常请直接使用 sync-upstream.sh 与 build.sh"
        }
    }

    private func start(_ command: String, argument: String? = nil) {
        guard !running, !repository.isEmpty else { return }
        let root = URL(fileURLWithPath: repository)
        let script = root.appendingPathComponent("scripts/local-update.py")
        var arguments = ["python3", script.path, command, "--json"]
        if command == "apply", let argument { arguments += ["--upstream", argument] }
        if command == "rollback", let argument { arguments += ["--build", argument] }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aime-local-update-ui", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let output = directory.appendingPathComponent(UUID().uuidString + ".json")
            guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else { return }
            let handle = try FileHandle(forWritingTo: output)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            try handle.close()
            running = true
            notice = command == "check" ? "正在检查稳定版" : "本机更新命令正在执行"
            // Process is retained by this task, independently of view refreshes.
            Task { @MainActor in
                while process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
                defer { try? FileManager.default.removeItem(at: output); running = false }
                guard let data = try? Data(contentsOf: output),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    notice = "本机更新未返回有效结果，当前安装状态请查更新记录"; return
                }
                if let build = value["rollback_build"] as? String { rollbackBuild = build }
                if value["ok"] as? Bool == true {
                    if command == "check" {
                        upstream = value["upstream_commit"] as? String
                        installationConfigured = (value["installation"] as? [String: Any])?["configured"] as? Bool == true
                        notice = "可集成稳定版：\(value["version"] as? String ?? "已锁定提交")"
                        if !installationConfigured { notice += "；安装条件尚未配置" }
                    } else { notice = command == "rollback" ? "已恢复上版" : "本机更新完成" }
                } else {
                    let error = value["error"] as? [String: Any]
                    notice = error?["message"] as? String ?? "本机更新已停止"
                    if command == "check" { upstream = nil }
                }
            }
        } catch { running = false; notice = "无法启动本机更新：\(error.localizedDescription)" }
    }
}
