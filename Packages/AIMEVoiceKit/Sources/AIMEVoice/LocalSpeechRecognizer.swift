// Cohere prompt selection adapts FluidVoice ExternalCoreMLTranscriptionProvider
// at 2ca292d173f0ca6ab11cfb93fb52ace83e82248e (GPL-3.0).
// See licenses/fluidvoice-source.md and licenses/fluidvoice.LICENSE.txt.
import Foundation
import OSLog
import TranscribeCpp
#if arch(arm64)
import FluidAudio
#endif

/// One inference at a time, including across XPC connections. Weights stay out of IMK.
actor LocalSpeechRecognizer {
    static let shared = LocalSpeechRecognizer()
    private let logger = Logger(subsystem: "app.zool.aime.voice", category: "latency")
    private var busy = false
    private var loadedModel: LocalSpeechModel?
    private var whisper: Model?
    #if arch(arm64)
    private var cohere: CohereRecognitionEngine?
    private var coherePrompt: [Int] = []
    #endif

    func checkAvailability(_ model: LocalSpeechModel) throws {
        guard !busy else { throw LocalSpeechModelError.busy }
        guard model.isAvailable else { throw LocalSpeechModelError.unavailable }
        guard model.isDownloaded else { throw LocalSpeechModelError.notDownloaded }
    }

    func transcribe(_ audio: RecordedAudio, model: LocalSpeechModel) async throws -> String {
        try Task.checkCancellation()
        try checkAvailability(model)
        busy = true
        defer { busy = false }
        var samples = try Self.samples(from: audio.wav)
        guard samples.count >= 1_600 else { throw VoiceTranscriptionError.emptyRecording }
        try await loadModelIfNeeded(model)
        let result: String
        if model == .cohere {
            #if arch(arm64)
            guard let cohere else { throw LocalSpeechModelError.invalidArtifacts }
            result = try await cohere.transcribe(audioSamples: samples, promptIDs: coherePrompt)
            #else
            throw LocalSpeechModelError.unavailable
            #endif
        } else {
            guard let whisper else { throw LocalSpeechModelError.invalidArtifacts }
            // The native Whisper frontend requires at least one second; preserve
            // short utterances by padding silence instead of rejecting them.
            if samples.count < 16_000 { samples += Array(repeating: 0, count: 16_000 - samples.count) }
            // A fresh session belongs to this operation only; never share it across awaits.
            result = try await Self.transcribeWhisper(samples, using: whisper)
        }
        try Task.checkCancellation()
        let text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceRecognitionError.recognitionFailed }
        return text
    }

    // The recording session owns this task; loading overlaps microphone capture
    // without delaying capture startup or introducing another audio buffer.
    func prepareModel(_ model: LocalSpeechModel) async throws {
        try Task.checkCancellation()
        try checkAvailability(model)
        busy = true
        defer { busy = false }
        try await loadModelIfNeeded(model)
        #if arch(arm64)
        if model == .cohere, let cohere {
            try await cohere.prepareForRecording()
        }
        #endif
    }

    private func loadModelIfNeeded(_ model: LocalSpeechModel) async throws {
        if loadedModel != model {
            let startedAt = Date()
            whisper = nil
            #if arch(arm64)
            cohere = nil
            coherePrompt = []
            #endif
            loadedModel = nil
            if model == .cohere {
                #if arch(arm64)
                let prompt = try Self.mandarinPrompt(at: model.directory)
                let manager = CohereRecognitionEngine()
                try await manager.loadModels(from: model.directory, computeConfiguration: .aneSmall)
                try Task.checkCancellation()
                cohere = manager
                coherePrompt = prompt
                #else
                throw LocalSpeechModelError.unavailable
                #endif
            } else {
                try Transcribe.ensureCompatible()
                try Transcribe.initBackends()
                #if arch(arm64)
                let backend: Backend = Transcribe.backendAvailable(.metal) ? .metal : .cpu
                #else
                let backend: Backend = .cpu
                #endif
                whisper = try Model(path: model.directory.appendingPathComponent(model.fileName).path,
                                    options: ModelOptions(backend: backend))
                try Task.checkCancellation()
            }
            loadedModel = model
            let elapsed = Date().timeIntervalSince(startedAt) * 1000
            logger.notice("stage=localModelLoad model=\(model.rawValue, privacy: .public) elapsedMs=\(elapsed)")
        }
    }

    // Session is non-Sendable. Create it in a nonisolated operation and keep
    // all access here while the actor's busy flag excludes another inference.
    nonisolated private static func transcribeWhisper(_ samples: [Float], using model: Model) async throws -> String {
        let session = try model.session()
        let transcript = try await session.run(samples, options: RunOptions(language: nil))
        return transcript.text
    }

    #if arch(arm64)
    private static func mandarinPrompt(at directory: URL) throws -> [Int] {
        struct Manifest: Decodable {
            let model_id: String
            let sample_rate: Int
            let prompt_ids: [Int]
            let id_to_token: [String]
        }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("coreml_manifest.json")))
        let languageTokens = Set(["de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt", "vi", "zh", "ar", "el"].map { "<|\($0)|>" })
        guard manifest.model_id == "CohereLabs/cohere-transcribe-03-2026",
              manifest.sample_rate == 16_000,
              let chinese = manifest.id_to_token.firstIndex(of: "<|zh|>"),
              !manifest.prompt_ids.isEmpty,
              manifest.prompt_ids.allSatisfy({ manifest.id_to_token.indices.contains($0) }),
              manifest.prompt_ids.contains(where: { languageTokens.contains(manifest.id_to_token[$0]) }) else {
            throw LocalSpeechModelError.invalidArtifacts
        }
        return manifest.prompt_ids.map { languageTokens.contains(manifest.id_to_token[$0]) ? chinese : $0 }
    }
    #endif

    /// Read RIFF chunks rather than assuming every WAV has a 44-byte header.
    private static func samples(from wav: Data) throws -> [Float] {
        let bytes = [UInt8](wav)
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> Int { uint16(offset) | uint16(offset + 2) << 16 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8) else { throw VoiceCaptureError.conversionFailed }
        var offset = 12
        var validFormat = false
        var pcm: Range<Int>?
        while offset <= bytes.count - 8 {
            let size = uint32(offset + 4)
            let start = offset + 8
            guard size <= bytes.count - start else { throw VoiceCaptureError.conversionFailed }
            let kind = Array(bytes[offset..<offset + 4])
            if kind == Array("fmt ".utf8) {
                guard size >= 16, uint16(start) == 1, uint16(start + 2) == 1,
                      uint32(start + 4) == 16_000, uint16(start + 12) == 2,
                      uint16(start + 14) == 16 else { throw VoiceCaptureError.conversionFailed }
                validFormat = true
            } else if kind == Array("data".utf8) {
                guard size.isMultiple(of: 2), size <= 16_000 * 2 * 300 else { throw VoiceCaptureError.conversionFailed }
                pcm = start..<start + size
            }
            offset = start + size + (size % 2)
        }
        guard validFormat, let pcm else { throw VoiceCaptureError.conversionFailed }
        return stride(from: pcm.lowerBound, to: pcm.upperBound, by: 2).map {
            Float(Int16(bitPattern: UInt16(uint16($0)))) / 32_768
        }
    }
}
