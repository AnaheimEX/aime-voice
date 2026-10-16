import AppKit
import SwiftUI

/// The local CLI owns integration and installation. Closing Settings does not
/// terminate it: output goes to a file, never a pipe owned by the UI process.
struct LocalIntegrationControls: View {
    @AppStorage("localIntegrationRepository") private var repository = ""
    @State private var running = false
    @State private var notice = ""
    @State private var installationConfigured = false
    @State private var upstream: String?
    @State private var rollbackBuild: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("本机集成更新").font(.caption.weight(.semibold))
                Button(repository.isEmpty ? "选择源码目录…" : "更换目录…", action: chooseRepository)
                Button("检查上游") { start("check") }.disabled(repository.isEmpty || running)
                Button("同步重建") { start("apply", argument: upstream) }
                    .disabled(upstream == nil || !installationConfigured || running)
                Button("回退上版") { start("rollback", argument: rollbackBuild) }
                    .disabled(rollbackBuild == nil || !installationConfigured || running)
                if running { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(Theme.secondaryText) }
        }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择已配置本机集成基线的AIME源码目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/local-update.py").path) else {
            notice = "该目录没有本机更新命令"; return
        }
        repository = url.path
        upstream = nil; rollbackBuild = nil; installationConfigured = false
        notice = "先检查上游；缺少集成基线或安全安装条件时会停止"
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
