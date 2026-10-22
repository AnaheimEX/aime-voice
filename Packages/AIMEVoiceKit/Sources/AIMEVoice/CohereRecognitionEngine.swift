// Adapted from FluidAudio eb1e6628998e47022799d305b52c2680d3576801, Apache-2.0.
// Local changes: preserve UTF-8 byte tokens, split saturated decoder chunks,
// check cancellation, and cap initial Chinese chunks to fit the decoder budget.
#if arch(arm64)
import FluidAudio
@preconcurrency import AVFoundation
@preconcurrency import CoreML
import Foundation
import OSLog

@available(macOS 15, iOS 18, *)
enum CohereTranscribeDecoderMode: String, Sendable {
    case cached
    case fullSequence
}

@available(macOS 15, iOS 18, *)
private struct CohereTranscribeEncoderStageOutput: @unchecked Sendable {
    let frontMs: Double
    let encMs: Double
    let crossKVms: Double
    let encoderHidden: MLMultiArray
    let encoderValid: Int
    let crossK: MLMultiArray?
    let crossV: MLMultiArray?
}

@available(macOS 15, iOS 18, *)
actor CohereRecognitionEngine {
    private var models: CohereTranscribeAsrModels?
    private var lastEncoderUse: ContinuousClock.Instant?
    private let logger = Logger(subsystem: "FluidAudio", category: "CohereTranscribeAsrManager")

    init() {}

    func loadModels(
        from directory: URL,
        computeUnits: MLComputeUnits = .cpuAndGPU
    ) async throws {
        try await self.loadModels(
            from: directory,
            computeConfiguration: .init(uniform: computeUnits)
        )
    }

    func loadModels(
        from directory: URL,
        computeConfiguration: CohereTranscribeComputeConfiguration
    ) async throws {
        self.models = try await CohereTranscribeAsrModels.load(
            from: directory,
            computeConfiguration: computeConfiguration
        )
        self.logger.info("Cohere Transcribe CoreML models loaded from \(directory.path, privacy: .public)")
    }

    // Wake the fixed-shape encoder once at recording start after inactivity.
    // No decoder is run, no text is produced, and no periodic timer keeps the GPU busy.
    func prepareForRecording() throws {
        try Task.checkCancellation()
        guard let models else { throw CohereTranscribeAsrError.generationFailed("Models not loaded") }
        if let lastEncoderUse, lastEncoderUse.duration(to: .now) < .seconds(30) { return }
        let started = ContinuousClock.now
        let silence = [Float](repeating: 0, count: models.manifest.sampleRate)
        let chunk = CohereAudioChunkPlanner.Chunk(startSample: 0, endSample: silence.count)
        let inputs = try buildChunkInputs(chunk: chunk, audioSamples: silence, manifest: models.manifest)
        _ = try runEncoderStage(frontInputs: inputs, models: models)
        try Task.checkCancellation()
        lastEncoderUse = .now
        let elapsed = started.duration(to: .now)
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        logger.notice("stage=cohereEncoderWarmup elapsedMs=\(milliseconds)")
    }

    func transcribe(
        audioSamples: [Float],
        decoderMode: CohereTranscribeDecoderMode = .cached,
        maxNewTokens: Int? = nil,
        promptIDs: [Int]? = nil
    ) async throws -> String {
        guard let models else {
            throw CohereTranscribeAsrError.generationFailed("Models not loaded")
        }
        guard audioSamples.isEmpty == false else { return "" }

        let chunks = CohereAudioChunkPlanner.makeChunks(
            audioSamples: audioSamples,
            sampleRate: models.manifest.sampleRate,
            maxAudioSamples: min(models.manifest.maxAudioSamples, models.manifest.sampleRate * 8),
            boundarySearchSeconds: 2
        )
        let startedAt = Date()
        let audioSeconds = Double(audioSamples.count) / Double(models.manifest.sampleRate)
        self.logger.info(
            "Cohere transcribe start [samples=\(audioSamples.count), audioSeconds=\(audioSeconds, format: .fixed(precision: 2)), decoderMode=\(decoderMode.rawValue, privacy: .public), chunks=\(chunks.count), chunking=energy-boundary]"
        )

        var chunkTexts: [String] = []
        for chunk in chunks {
            try Task.checkCancellation()
            chunkTexts.append(try transcribeChunk(chunk, samples: audioSamples, models: models,
                                                  decoderMode: decoderMode, maxNewTokens: maxNewTokens,
                                                  promptIDs: promptIDs))
        }

        lastEncoderUse = .now
        let merged = CohereAudioChunkPlanner.joinChunkTexts(chunkTexts)
        let elapsed = Date().timeIntervalSince(startedAt)
        let rtf = audioSeconds > 0 ? elapsed / audioSeconds : 0
        self.logger.info(
            "Cohere transcribe finished in \(elapsed, format: .fixed(precision: 2))s [audioSeconds=\(audioSeconds, format: .fixed(precision: 2)), rtf=\(rtf, format: .fixed(precision: 2))x, chars=\(merged.count)]"
        )
        return merged
    }

    // A fixed Core ML decoder has a finite context. Missing EOS means that
    // returning its text would silently discard the rest of this audio chunk.
    private func transcribeChunk(_ chunk: CohereAudioChunkPlanner.Chunk, samples: [Float],
                                 models: CohereTranscribeAsrModels,
                                 decoderMode: CohereTranscribeDecoderMode,
                                 maxNewTokens: Int?, promptIDs: [Int]?) throws -> String {
        try Task.checkCancellation()
        let tokens = try runPipeline(frontInputs: buildChunkInputs(chunk: chunk, audioSamples: samples,
                                                                  manifest: models.manifest),
                                     models: models, decoderMode: decoderMode,
                                     maxNewTokens: maxNewTokens, promptIDs: promptIDs)
        let generated = tokens.dropFirst((promptIDs ?? models.manifest.promptIDs).count)
        if let eos = models.manifest.eosTokenID, generated.contains(Int32(eos)) {
            return decodeTokens(tokens, manifest: models.manifest)
        }
        let rate = models.manifest.sampleRate
        guard chunk.sampleCount > rate else {
            throw CohereTranscribeAsrError.generationFailed("识别输出达到长度上限，未提交不完整文字，请重试")
        }
        let midpoint = (chunk.startSample + chunk.endSample) / 2
        let split = CohereAudioChunkPlanner.findQuietestSplitPoint(
            samples, startSample: max(chunk.startSample + rate / 4, midpoint - rate / 4),
            endSample: min(chunk.endSample - rate / 4, midpoint + rate / 4))
        let left = CohereAudioChunkPlanner.Chunk(startSample: chunk.startSample, endSample: split)
        let right = CohereAudioChunkPlanner.Chunk(startSample: split, endSample: chunk.endSample)
        return CohereAudioChunkPlanner.joinChunkTexts([
            try transcribeChunk(left, samples: samples, models: models, decoderMode: decoderMode,
                                maxNewTokens: maxNewTokens, promptIDs: promptIDs),
            try transcribeChunk(right, samples: samples, models: models, decoderMode: decoderMode,
                                maxNewTokens: maxNewTokens, promptIDs: promptIDs),
        ])
    }

    private func runPipeline(
        frontInputs: MLDictionaryFeatureProvider,
        models: CohereTranscribeAsrModels,
        decoderMode: CohereTranscribeDecoderMode,
        maxNewTokens: Int?,
        promptIDs: [Int]?
    ) throws -> [Int32] {
        switch decoderMode {
        case .fullSequence:
            return try self.runFullSequencePipeline(
                frontInputs: frontInputs,
                models: models,
                maxNewTokens: maxNewTokens,
                promptIDs: promptIDs
            )
        case .cached:
            guard self.canRunCachedDecoder(with: models) else {
                self.logger.warning("Cached decoder metadata missing; falling back to full-sequence decode.")
                return try self.runFullSequencePipeline(
                    frontInputs: frontInputs,
                    models: models,
                    maxNewTokens: maxNewTokens,
                    promptIDs: promptIDs
                )
            }
            return try self.runCachedPipeline(
                frontInputs: frontInputs,
                models: models,
                maxNewTokens: maxNewTokens,
                promptIDs: promptIDs
            )
        }
    }

    private func canRunCachedDecoder(with models: CohereTranscribeAsrModels) -> Bool {
        guard let metadata = models.manifest.decoderCached, models.cachedDecoder != nil else {
            return false
        }
        return metadata.cacheKOutput != nil && metadata.cacheVOutput != nil
    }

    nonisolated private func buildChunkInputs(
        chunk: CohereAudioChunkPlanner.Chunk,
        audioSamples: [Float],
        manifest: CohereTranscribeAsrManifest
    ) throws -> MLDictionaryFeatureProvider {
        var segment = Array(audioSamples[chunk.range])
        let rawLength = segment.count

        if segment.count < manifest.maxAudioSamples {
            segment += Array(repeating: 0, count: manifest.maxAudioSamples - segment.count)
        }

        self.applyPreemphasis(
            &segment,
            rawLength: rawLength,
            coefficient: manifest.preemph ?? 0.97
        )

        let audioArray = try self.makeFloatArray(
            shape: [1, manifest.maxAudioSamples],
            values: segment
        )
        let audioLengthArray = try self.makeIntArray(shape: [1], values: [Int32(rawLength)])

        return try MLDictionaryFeatureProvider(dictionary: [
            manifest.frontend.inputs[0]: MLFeatureValue(multiArray: audioArray),
            manifest.frontend.inputs[1]: MLFeatureValue(multiArray: audioLengthArray),
        ])
    }

    nonisolated private func runEncoderStage(
        frontInputs: MLDictionaryFeatureProvider,
        models: CohereTranscribeAsrModels
    ) throws -> CohereTranscribeEncoderStageOutput {
        let manifest = models.manifest
        let frontStartedAt = Date()
        let frontOut = try models.frontend.prediction(from: frontInputs)
        let frontMs = Date().timeIntervalSince(frontStartedAt) * 1000
        guard
            let inputFeatures = frontOut.featureValue(for: manifest.frontend.outputs[0])?.multiArrayValue,
            let featureLength = frontOut.featureValue(for: manifest.frontend.outputs[1])?.multiArrayValue
        else {
            throw CohereTranscribeAsrError.invalidOutput("Frontend outputs missing")
        }

        let encoderInputs = try MLDictionaryFeatureProvider(dictionary: [
            manifest.encoder.inputs[0]: MLFeatureValue(multiArray: inputFeatures),
            manifest.encoder.inputs[1]: MLFeatureValue(multiArray: featureLength),
        ])
        let encoderStartedAt = Date()
        let encoderOut = try models.encoder.prediction(from: encoderInputs)
        let encoderMs = Date().timeIntervalSince(encoderStartedAt) * 1000
        guard
            let encoderHidden = encoderOut.featureValue(for: manifest.encoder.outputs[0])?.multiArrayValue,
            let encoderLengthOut = encoderOut.featureValue(for: manifest.encoder.outputs[1])?.multiArrayValue
        else {
            throw CohereTranscribeAsrError.invalidOutput("Encoder outputs missing")
        }

        let encoderHiddenContiguous = try self.toContiguous(encoderHidden)
        let encoderValidRaw = Int(encoderLengthOut[0].doubleValue.rounded())
        let encoderValid = max(1, min(manifest.maxEncoderFrames, encoderValidRaw))

        var crossK: MLMultiArray?
        var crossV: MLMultiArray?
        var crossKVms: Double = 0
        if
            let crossKVMeta = manifest.crossKVProjector,
            let crossKVProjector = models.crossKVProjector
        {
            let inputName = crossKVMeta.inputs.first ?? "encoder_hidden_states"
            let crossKVStartedAt = Date()
            let crossKVInputs = try MLDictionaryFeatureProvider(dictionary: [
                inputName: MLFeatureValue(multiArray: encoderHiddenContiguous)
            ])
            let crossKVOutput = try crossKVProjector.prediction(from: crossKVInputs)
            crossKVms = Date().timeIntervalSince(crossKVStartedAt) * 1000
            if let crossKOutput = crossKVMeta.crossKOutput ?? crossKVMeta.outputs.first {
                crossK = crossKVOutput.featureValue(for: crossKOutput)?.multiArrayValue
            }
            if let crossVOutput = crossKVMeta.crossVOutput ?? crossKVMeta.outputs.dropFirst().first {
                crossV = crossKVOutput.featureValue(for: crossVOutput)?.multiArrayValue
            }
        }

        return CohereTranscribeEncoderStageOutput(
            frontMs: frontMs,
            encMs: encoderMs,
            crossKVms: crossKVms,
            encoderHidden: encoderHiddenContiguous,
            encoderValid: encoderValid,
            crossK: crossK,
            crossV: crossV
        )
    }

    nonisolated private func runFullSequencePipeline(
        frontInputs: MLDictionaryFeatureProvider,
        models: CohereTranscribeAsrModels,
        maxNewTokens: Int?,
        promptIDs: [Int]?
    ) throws -> [Int32] {
        let manifest = models.manifest
        let encoderStage = try self.runEncoderStage(frontInputs: frontInputs, models: models)
        let encoderHidden = encoderStage.encoderHidden
        let encoderValid = encoderStage.encoderValid
        let generationPromptIDs = promptIDs ?? manifest.promptIDs

        let vocabSize = manifest.idToToken.count
        let totalMaxNewTokens = maxNewTokens ?? manifest.defaultMaxNewTokens
        let padToken = Int32(manifest.padTokenID ?? 0)
        var inputIDs = Array(repeating: padToken, count: manifest.decoderMaxLen)
        var attentionMask = Array(repeating: Int32(0), count: manifest.decoderMaxLen)

        for (index, tokenID) in generationPromptIDs.enumerated() where index < manifest.decoderMaxLen {
            inputIDs[index] = Int32(tokenID)
            attentionMask[index] = 1
        }

        let crossAttentionMask = try self.makeCrossAttentionMask(
            validLength: encoderValid,
            totalLength: manifest.maxEncoderFrames,
            useFloat16: manifest.isFp16
        )

        var currentIndex = generationPromptIDs.count - 1
        for _ in 0..<totalMaxNewTokens {
            try Task.checkCancellation()
            if currentIndex + 1 >= manifest.decoderMaxLen {
                break
            }

            let idsArray = try self.makeIntArray(shape: [1, manifest.decoderMaxLen], values: inputIDs)
            let maskArray = try self.makeIntArray(shape: [1, manifest.decoderMaxLen], values: attentionMask)
            let decoderInputs = try MLDictionaryFeatureProvider(dictionary: [
                manifest.decoder.inputs[0]: MLFeatureValue(multiArray: encoderHidden),
                manifest.decoder.inputs[1]: MLFeatureValue(multiArray: idsArray),
                manifest.decoder.inputs[2]: MLFeatureValue(multiArray: maskArray),
                manifest.decoder.inputs[3]: MLFeatureValue(multiArray: crossAttentionMask),
            ])

            let decoderOut = try models.decoder.prediction(from: decoderInputs)
            guard let logits = decoderOut.featureValue(for: manifest.decoder.outputs[0])?.multiArrayValue else {
                throw CohereTranscribeAsrError.invalidOutput("Decoder logits missing")
            }

            let next = self.argmaxSlice(logits, tokenIndex: currentIndex, vocabSize: vocabSize)
            currentIndex += 1
            inputIDs[currentIndex] = next
            attentionMask[currentIndex] = 1

            if let eosTokenID = manifest.eosTokenID, Int(next) == eosTokenID {
                break
            }
        }

        return Array(inputIDs[0...currentIndex])
    }

    nonisolated private func runCachedPipeline(
        frontInputs: MLDictionaryFeatureProvider,
        models: CohereTranscribeAsrModels,
        maxNewTokens: Int?,
        promptIDs: [Int]?
    ) throws -> [Int32] {
        let encoderStage = try self.runEncoderStage(frontInputs: frontInputs, models: models)
        let decodeStartedAt = Date()
        let tokens = try self.runCachedDecoderOnly(
            encoderStage: encoderStage,
            models: models,
            maxNewTokens: maxNewTokens,
            promptIDs: promptIDs
        )
        let decodeMs = Date().timeIntervalSince(decodeStartedAt) * 1000
        logger.notice("stage=cohereChunk frontendMs=\(encoderStage.frontMs) encoderMs=\(encoderStage.encMs) crossKVMs=\(encoderStage.crossKVms) decoderMs=\(decodeMs) tokens=\(tokens.count)")
        return tokens
    }

    nonisolated private func runCachedDecoderOnly(
        encoderStage: CohereTranscribeEncoderStageOutput,
        models: CohereTranscribeAsrModels,
        maxNewTokens: Int?,
        promptIDs: [Int]?
    ) throws -> [Int32] {
        guard
            let cachedMetadata = models.manifest.decoderCached,
            let cachedDecoder = models.cachedDecoder,
            let cacheKOutput = cachedMetadata.cacheKOutput,
            let cacheVOutput = cachedMetadata.cacheVOutput
        else {
            throw CohereTranscribeAsrError.generationFailed("Cached decoder is unavailable")
        }

        let manifest = models.manifest
        let generationPromptIDs = promptIDs ?? manifest.promptIDs
        let maxTokens = maxNewTokens ?? manifest.defaultMaxNewTokens
        let cacheShape = [cachedMetadata.numLayers, cachedMetadata.numHeads, manifest.decoderMaxLen, cachedMetadata.headDim]
            .map(NSNumber.init)
        let cacheType: MLMultiArrayDataType = manifest.isFp16 ? .float16 : .float32
        let cacheBytesPerElement = manifest.isFp16 ? 2 : 4
        let cacheElementCount = cachedMetadata.numLayers * cachedMetadata.numHeads * manifest.decoderMaxLen * cachedMetadata.headDim

        let vocabSize = manifest.idToToken.count
        let logitsShape = [1, vocabSize].map(NSNumber.init)
        let logitsBuffer = try MLMultiArray(shape: logitsShape, dataType: cacheType)

        let cacheKA = try MLMultiArray(shape: cacheShape, dataType: cacheType)
        let cacheVA = try MLMultiArray(shape: cacheShape, dataType: cacheType)
        let cacheKB = try MLMultiArray(shape: cacheShape, dataType: cacheType)
        let cacheVB = try MLMultiArray(shape: cacheShape, dataType: cacheType)
        memset(cacheKA.dataPointer, 0, cacheElementCount * cacheBytesPerElement)
        memset(cacheVA.dataPointer, 0, cacheElementCount * cacheBytesPerElement)

        let crossAttentionMask = try self.makeCrossAttentionMask(
            validLength: encoderStage.encoderValid,
            totalLength: manifest.maxEncoderFrames,
            useFloat16: manifest.isFp16
        )

        let inputIDArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let stepArray = try MLMultiArray(shape: [1], dataType: .int32)
        let inputIDName = self.cachedDecoderInputName(metadata: cachedMetadata, preferred: "input_id", fallbackIndex: 1)
        let cacheKInputName = self.cachedDecoderInputName(metadata: cachedMetadata, preferred: "cache_k", fallbackIndex: 2)
        let cacheVInputName = self.cachedDecoderInputName(metadata: cachedMetadata, preferred: "cache_v", fallbackIndex: 3)
        let stepInputName = self.cachedDecoderInputName(metadata: cachedMetadata, preferred: "step", fallbackIndex: 4)
        let crossAttentionMaskName = self.cachedDecoderInputName(metadata: cachedMetadata, preferred: "cross_attention_mask", fallbackIndex: 5)

        let featureProvider = self.makeCachedDecoderFeatureProvider(
            metadata: cachedMetadata,
            encoderStage: encoderStage,
            inputIDArray: inputIDArray,
            cacheKA: cacheKA,
            cacheVA: cacheVA,
            stepArray: stepArray,
            crossAttentionMask: crossAttentionMask
        )

        let optionsA = MLPredictionOptions()
        optionsA.outputBackings = [
            cachedMetadata.logitsOutput: logitsBuffer,
            cacheKOutput: cacheKB,
            cacheVOutput: cacheVB,
        ]
        let optionsB = MLPredictionOptions()
        optionsB.outputBackings = [
            cachedMetadata.logitsOutput: logitsBuffer,
            cacheKOutput: cacheKA,
            cacheVOutput: cacheVA,
        ]

        var useA = true

        func runStep(tokenID: Int32, stepIndex: Int32) throws -> MLMultiArray {
            inputIDArray[0] = NSNumber(value: tokenID)
            stepArray[0] = NSNumber(value: stepIndex)

            let inputCacheK = useA ? cacheKA : cacheKB
            let inputCacheV = useA ? cacheVA : cacheVB
            featureProvider.update(inputIDName, inputIDArray)
            featureProvider.update(cacheKInputName, inputCacheK)
            featureProvider.update(cacheVInputName, inputCacheV)
            featureProvider.update(stepInputName, stepArray)
            featureProvider.update(crossAttentionMaskName, crossAttentionMask)

            let options = useA ? optionsA : optionsB
            _ = try cachedDecoder.prediction(from: featureProvider, options: options)
            useA.toggle()
            return logitsBuffer
        }

        var generated = generationPromptIDs.map(Int32.init)
        var lastLogits: MLMultiArray?
        for (index, tokenID) in generationPromptIDs.enumerated() {
            try Task.checkCancellation()
            lastLogits = try runStep(tokenID: Int32(tokenID), stepIndex: Int32(index))
        }

        var currentIndex = generationPromptIDs.count
        if let lastLogits {
            let next = self.argmax1D(lastLogits)
            generated.append(next)
            if let eosTokenID = manifest.eosTokenID, Int(next) == eosTokenID {
                return generated
            }
        }

        for _ in 1..<maxTokens {
            try Task.checkCancellation()
            if currentIndex >= manifest.decoderMaxLen {
                break
            }
            let logits = try runStep(tokenID: generated.last ?? 0, stepIndex: Int32(currentIndex))
            let next = self.argmax1D(logits)
            generated.append(next)
            currentIndex += 1
            if let eosTokenID = manifest.eosTokenID, Int(next) == eosTokenID {
                break
            }
        }

        return generated
    }

    nonisolated private func makeCachedDecoderFeatureProvider(
        metadata: CohereTranscribeCachedDecoderMeta,
        encoderStage: CohereTranscribeEncoderStageOutput,
        inputIDArray: MLMultiArray,
        cacheKA: MLMultiArray,
        cacheVA: MLMultiArray,
        stepArray: MLMultiArray,
        crossAttentionMask: MLMultiArray
    ) -> FastFeatureProvider {
        let inputIDName = self.cachedDecoderInputName(metadata: metadata, preferred: "input_id", fallbackIndex: 1)
        let cacheKInputName = self.cachedDecoderInputName(metadata: metadata, preferred: "cache_k", fallbackIndex: 2)
        let cacheVInputName = self.cachedDecoderInputName(metadata: metadata, preferred: "cache_v", fallbackIndex: 3)
        let stepInputName = self.cachedDecoderInputName(metadata: metadata, preferred: "step", fallbackIndex: 4)
        let crossAttentionMaskName = self.cachedDecoderInputName(metadata: metadata, preferred: "cross_attention_mask", fallbackIndex: 5)

        if let crossK = encoderStage.crossK, let crossV = encoderStage.crossV {
            let crossKName = self.cachedDecoderInputName(metadata: metadata, preferred: "cross_k", fallbackIndex: 0)
            let crossVName = self.cachedDecoderInputName(metadata: metadata, preferred: "cross_v", fallbackIndex: 1)
            return FastFeatureProvider([
                (crossKName, crossK),
                (crossVName, crossV),
                (inputIDName, inputIDArray),
                (cacheKInputName, cacheKA),
                (cacheVInputName, cacheVA),
                (stepInputName, stepArray),
                (crossAttentionMaskName, crossAttentionMask),
            ])
        }

        let encoderHiddenName = self.cachedDecoderInputName(metadata: metadata, preferred: "encoder_hidden_states", fallbackIndex: 0)
        return FastFeatureProvider([
            (encoderHiddenName, encoderStage.encoderHidden),
            (inputIDName, inputIDArray),
            (cacheKInputName, cacheKA),
            (cacheVInputName, cacheVA),
            (stepInputName, stepArray),
            (crossAttentionMaskName, crossAttentionMask),
        ])
    }

    nonisolated private func cachedDecoderInputName(
        metadata: CohereTranscribeCachedDecoderMeta,
        preferred: String,
        fallbackIndex: Int
    ) -> String {
        if metadata.inputs.contains(preferred) {
            return preferred
        }
        if metadata.inputs.indices.contains(fallbackIndex) {
            return metadata.inputs[fallbackIndex]
        }
        return preferred
    }

    nonisolated private func decodeTokens(
        _ tokenIDs: [Int32],
        manifest: CohereTranscribeAsrManifest
    ) -> String {
        CohereTokenText.decode(tokenIDs, vocabulary: manifest.idToToken,
                               eos: manifest.eosTokenID, pad: manifest.padTokenID)
    }
}

#endif
