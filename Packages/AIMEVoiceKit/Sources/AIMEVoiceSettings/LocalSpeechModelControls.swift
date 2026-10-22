import AIMEVoice
import AppKit
import Foundation
import SwiftUI

struct LocalSpeechModelControls: View {
    @Binding var model: LocalSpeechModel
    @State private var installed = false
    @State private var downloading = false
    @State private var progress = 0.0
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()

    var body: some View {
        Group {
            Picker("本地识别模型", selection: $model) {
                ForEach(LocalSpeechModel.allCases) { item in
                    Text(item.isAvailable ? item.title : item.title + " · 需要 Apple Silicon")
                        .tag(item).disabled(!item.isAvailable)
                }
            }
            .disabled(downloading)
            HStack {
                Text(installed ? "已下载 · 首次识别需要加载模型" : "尚未下载")
                    .foregroundStyle(.secondary)
                Spacer()
                if downloading {
                    ProgressView().controlSize(.small)
                    Text(progress == 0 ? "正在下载…" : "已校验 \(Int(progress * 100))%")
                        .font(.caption)
                    Button("取消下载") { cancel() }
                } else if !installed {
                    Button("下载模型") { download() }
                        .disabled(!model.isAvailable)
                }
                Button("打开模型目录") {
                    let parent = model.directory.deletingLastPathComponent()
                    NSWorkspace.shared.open(parent)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("录音与识别在本机完成。Cohere 使用普通话；Whisper 自动识别语言，支持中文及中英混说。模型按需从 Hugging Face 下载，首次加载或 Core ML 编译可能较慢。")
                .font(.caption).foregroundStyle(.secondary)
            Text("当前本地后端不使用识别热词；语音词典的纠错规则仍在润色前替换一次。润色、翻译与决策继续使用下方所选服务。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { installed = model.isDownloaded }
        .onChange(of: model) { cancel(); installed = model.isDownloaded }
        .onDisappear { cancel() }
    }

    private func download() {
        cancel()
        let id = operationID
        let requested = model
        downloading = true
        progress = 0
        message = nil
        operation = Task { @MainActor in
            defer { if id == operationID { downloading = false; installed = requested.isDownloaded } }
            do {
                try await LocalSpeechModelStore.shared.download(requested) { value in
                    Task { @MainActor in
                        guard operationID == id else { return }
                        progress = value
                    }
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                message = "模型已下载并校验。保存设置后用于语音输入。"
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                message = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    private func cancel() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        downloading = false
        message = nil
    }
}
