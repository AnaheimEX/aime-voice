public import Foundation
import CryptoKit

/// Models and artifacts used by FluidVoice, independent of Rime and cloud profiles.
public enum LocalSpeechModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case cohere = "cohere-transcribe-6bit"
    case whisperSmall = "whisper-small"
    case whisperTurbo = "whisper-large-v3-turbo"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cohere: "Cohere Transcribe · 普通话 / 多语言（约 1.65 GB）"
        case .whisperSmall: "Whisper Small · 多语言（约 270 MB）"
        case .whisperTurbo: "Whisper Large v3 Turbo · 多语言（约 886 MB）"
        }
    }
    public var isAvailable: Bool {
        #if arch(arm64)
        true
        #else
        self != .cohere
        #endif
    }
    var repository: String {
        switch self {
        case .cohere: "BarathwajAnandan/cohere-transcribe-03-2026-CoreML-6bit"
        case .whisperSmall: "handy-computer/whisper-small-gguf"
        case .whisperTurbo: "handy-computer/whisper-large-v3-turbo-gguf"
        }
    }
    var fileName: String { rawValue + "-Q8_0.gguf" }
    var requiredRoots: Set<String> {
        if self != .cohere { return [fileName] }
        return ["coreml_manifest.json", "cohere_frontend.mlpackage", "cohere_encoder.mlpackage",
                "cohere_cross_kv_projector.mlpackage", "cohere_decoder_fullseq_masked.mlpackage",
                "cohere_decoder_cached.mlpackage"]
    }
    public var directory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/AIME/VoiceModels/\(rawValue)", isDirectory: true)
    }
    public var isDownloaded: Bool { (try? LocalSpeechModelStore.receipt(for: self)) != nil }
}

public enum LocalSpeechModelError: LocalizedError, Sendable {
    case unavailable, notDownloaded, invalidArtifacts, downloadFailed(Int), busy, modelDirectoryExists
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Cohere 本地识别需要 Apple Silicon Mac"
        case .notDownloaded: "请先在语音设置中下载所选本地识别模型"
        case .invalidArtifacts: "本地识别模型不完整或校验失败，请重新下载"
        case .downloadFailed(let status): "模型下载失败（HTTP \(status)）"
        case .busy: "本地模型正在处理任务，请稍后重试"
        case .modelDirectoryExists: "模型目录已有不完整内容，请打开模型目录，将对应目录移走后重新下载"
        }
    }
}

/// Explicit downloads only. Resolve main once, then pin every file to that commit.
public actor LocalSpeechModelStore {
    public static let shared = LocalSpeechModelStore()
    private var downloading = Set<LocalSpeechModel>()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration)
    }()

    struct Receipt: Codable {
        let model: LocalSpeechModel
        let revision: String
        let files: [FileRecord]
    }
    struct FileRecord: Codable {
        let path: String
        let size: Int64
        let sha256: String?
        let gitHash: String
    }
    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64
        let oid: String
        let lfs: LFS?
        struct LFS: Decodable { let oid: String; let size: Int64 }
    }

    static func receipt(for model: LocalSpeechModel) throws -> Receipt {
        let receipt = try JSONDecoder().decode(Receipt.self,
            from: Data(contentsOf: model.directory.appendingPathComponent("installation.json")))
        guard receipt.model == model, !receipt.files.isEmpty,
              receipt.revision.count == 40, receipt.revision.allSatisfy(\.isHexDigit),
              model.requiredRoots.isSubset(of: Set(receipt.files.compactMap { $0.path.split(separator: "/").first.map(String.init) })) else {
            throw LocalSpeechModelError.invalidArtifacts
        }
        for file in receipt.files {
            guard validPath(file.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: model.directory.appendingPathComponent(file.path).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.size else {
                throw LocalSpeechModelError.invalidArtifacts
            }
        }
        return receipt
    }

    public func download(_ model: LocalSpeechModel,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        guard model.isAvailable else { throw LocalSpeechModelError.unavailable }
        if model.isDownloaded { progress(1); return }
        guard !FileManager.default.fileExists(atPath: model.directory.path) else {
            throw LocalSpeechModelError.modelDirectoryExists
        }
        guard downloading.insert(model).inserted else { throw LocalSpeechModelError.busy }
        defer { downloading.remove(model) }
        struct Revision: Decodable { let sha: String }
        let info = try await Self.data("https://huggingface.co/api/models/\(model.repository)/revision/main")
        let revision = try JSONDecoder().decode(Revision.self, from: info).sha
        guard revision.count == 40, revision.allSatisfy(\.isHexDigit) else {
            throw LocalSpeechModelError.invalidArtifacts
        }
        var entries: [TreeEntry] = []
        var next: URL? = URL(string: "https://huggingface.co/api/models/\(model.repository)/tree/\(revision)?recursive=true&limit=1000")
        var pages = 0
        while let url = next {
            try Task.checkCancellation()
            pages += 1
            guard pages <= 20, url.scheme == "https", url.host == "huggingface.co" else {
                throw LocalSpeechModelError.invalidArtifacts
            }
            let (data, response) = try await Self.session.data(from: url)
            let http = try Self.checked(response)
            entries += try JSONDecoder().decode([TreeEntry].self, from: data)
            next = http.value(forHTTPHeaderField: "Link")?.components(separatedBy: ",")
                .first(where: { $0.contains("rel=\"next\"") }).flatMap { link in
                    guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end else { return nil }
                    return URL(string: String(link[link.index(after: start)..<end]))
                }
        }
        let files = entries.filter { entry in
            guard entry.type == "file", Self.validPath(entry.path), entry.size > 0 else { return false }
            let root = entry.path.split(separator: "/").first.map(String.init) ?? ""
            return model.requiredRoots.contains(root) || ["LICENSE", "LICENSE.md", "LICENSE.txt", "README.md", "NOTICE"].contains(entry.path)
        }
        guard Set(files.map(\.path)).count == files.count,
              model.requiredRoots.isSubset(of: Set(files.compactMap { $0.path.split(separator: "/").first.map(String.init) })),
              files.count <= 10_000,
              files.allSatisfy({ $0.size <= 8_000_000_000 }) else { throw LocalSpeechModelError.invalidArtifacts }
        let parent = model.directory.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var completed: Int64 = 0
        var records: [FileRecord] = []
        for file in files {
            try Task.checkCancellation()
            let components = file.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }
            let url = URL(string: "https://huggingface.co/\(model.repository)/resolve/\(revision)/\(components.joined(separator: "/"))")!
            let (temporary, response) = try await Self.session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            _ = try Self.checked(response)
            let attributes = try fm.attributesOfItem(atPath: temporary.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size else {
                throw LocalSpeechModelError.invalidArtifacts
            }
            try Self.verify(temporary, entry: file)
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: target)
            records.append(FileRecord(path: file.path, size: file.size, sha256: file.lfs?.oid, gitHash: file.oid))
            completed += file.size
            progress(min(0.99, Double(completed) / Double(max(total, 1))))
        }
        let receipt = Receipt(model: model, revision: revision, files: records)
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        // Keep any existing directory intact; never merge incomplete and fresh weights.
        if fm.fileExists(atPath: model.directory.path) { throw LocalSpeechModelError.modelDirectoryExists }
        try fm.moveItem(at: staging, to: model.directory)
        progress(1)
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw LocalSpeechModelError.invalidArtifacts }
        guard (200..<300).contains(http.statusCode) else { throw LocalSpeechModelError.downloadFailed(http.statusCode) }
        return http
    }
    private static func data(_ address: String) async throws -> Data {
        let (data, response) = try await session.data(from: URL(string: address)!)
        _ = try checked(response)
        return data
    }
    private static func verify(_ url: URL, entry: TreeEntry) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha256 = SHA256()
        var gitHash = Insecure.SHA1()
        gitHash.update(data: Data("blob \(entry.size)\0".utf8))
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            sha256.update(data: chunk)
            gitHash.update(data: chunk)
        }
        let actual = entry.lfs == nil ? gitHash.finalize().map { String(format: "%02x", $0) }.joined()
            : sha256.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == (entry.lfs?.oid ?? entry.oid) else { throw LocalSpeechModelError.invalidArtifacts }
    }
}
