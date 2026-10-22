// Adapted from FluidAudio eb1e6628998e47022799d305b52c2680d3576801, Apache-2.0.
// MLMultiArray helpers for CohereRecognitionEngine, unchanged from that adaptation.
#if arch(arm64)
@preconcurrency import CoreML
import Foundation

@available(macOS 15, iOS 18, *)
extension CohereRecognitionEngine {

    nonisolated func applyPreemphasis(
        _ audio: inout [Float],
        rawLength: Int,
        coefficient: Float
    ) {
        let count = min(rawLength, audio.count)
        guard count > 0 else { return }

        if count > 1 {
            for index in stride(from: count - 1, through: 1, by: -1) {
                audio[index] = audio[index] - coefficient * audio[index - 1]
            }
        }

        for index in count..<audio.count {
            audio[index] = 0
        }
    }

    nonisolated func makeCrossAttentionMask(
        validLength: Int,
        totalLength: Int,
        useFloat16: Bool
    ) throws -> MLMultiArray {
        let limitedValidLength = max(0, min(validLength, totalLength))
        let invalidValue: Float = -1e9
        var values = Array(repeating: invalidValue, count: totalLength)
        if limitedValidLength > 0 {
            for index in 0..<limitedValidLength {
                values[index] = 0
            }
        }

        if useFloat16 {
            return try self.makeFloat16Array(shape: [1, 1, 1, totalLength], values: values)
        }
        return try self.makeFloatArray(shape: [1, 1, 1, totalLength], values: values)
    }

    nonisolated func argmax1D(_ array: MLMultiArray) -> Int32 {
        let count = array.count
        if array.dataType == .float16 {
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: count)
            var bestIndex = 0
            var bestValue = pointer[0]
            for index in 1..<count {
                let current = pointer[index]
                if current > bestValue {
                    bestValue = current
                    bestIndex = index
                }
            }
            return Int32(bestIndex)
        }

        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: count)
        var bestIndex = 0
        var bestValue = pointer[0]
        for index in 1..<count {
            if pointer[index] > bestValue {
                bestValue = pointer[index]
                bestIndex = index
            }
        }
        return Int32(bestIndex)
    }

    nonisolated func argmaxSlice(
        _ array: MLMultiArray,
        tokenIndex: Int,
        vocabSize: Int
    ) -> Int32 {
        let strideT = array.strides[1].intValue
        let strideV = array.strides[2].intValue
        let base = tokenIndex * strideT
        var bestValue = array[base].doubleValue
        var bestIndex = 0

        for index in 1..<vocabSize {
            let value = array[base + index * strideV].doubleValue
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
        }

        return Int32(bestIndex)
    }

    nonisolated func toContiguous(_ array: MLMultiArray) throws -> MLMultiArray {
        let shape = array.shape.map(\.intValue)
        let totalCount = shape.reduce(1, *)
        let strides = array.strides.map(\.intValue)

        var expectedStride = 1
        var isContiguous = true
        for index in stride(from: shape.count - 1, through: 0, by: -1) {
            if strides[index] != expectedStride {
                isContiguous = false
                break
            }
            expectedStride *= shape[index]
        }

        if isContiguous {
            return array
        }

        let contiguous = try MLMultiArray(shape: array.shape, dataType: array.dataType)
        if array.dataType == .float16 {
            let source = array.dataPointer.bindMemory(to: UInt16.self, capacity: totalCount)
            let destination = contiguous.dataPointer.bindMemory(to: UInt16.self, capacity: totalCount)
            if shape.count == 3 {
                var outputIndex = 0
                for batch in 0..<shape[0] {
                    for time in 0..<shape[1] {
                        let base = batch * strides[0] + time * strides[1]
                        if strides[2] == 1 {
                            memcpy(destination + outputIndex, source + base, shape[2] * MemoryLayout<UInt16>.size)
                            outputIndex += shape[2]
                        } else {
                            for hidden in 0..<shape[2] {
                                destination[outputIndex] = source[base + hidden * strides[2]]
                                outputIndex += 1
                            }
                        }
                    }
                }
            }
        } else {
            let source = array.dataPointer.bindMemory(to: Float.self, capacity: totalCount)
            let destination = contiguous.dataPointer.bindMemory(to: Float.self, capacity: totalCount)
            if shape.count == 3 {
                var outputIndex = 0
                for batch in 0..<shape[0] {
                    for time in 0..<shape[1] {
                        let base = batch * strides[0] + time * strides[1]
                        if strides[2] == 1 {
                            memcpy(destination + outputIndex, source + base, shape[2] * MemoryLayout<Float>.size)
                            outputIndex += shape[2]
                        } else {
                            for hidden in 0..<shape[2] {
                                destination[outputIndex] = source[base + hidden * strides[2]]
                                outputIndex += 1
                            }
                        }
                    }
                }
            }
        }
        return contiguous
    }

    nonisolated func makeFloatArray(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float32)
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        _ = values.withUnsafeBufferPointer { buffer in
            memcpy(pointer, buffer.baseAddress, values.count * MemoryLayout<Float>.stride)
        }
        return array
    }

    nonisolated func makeFloat16Array(shape: [Int], values: [Float]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .float16)
        let pointer = array.dataPointer.bindMemory(to: UInt16.self, capacity: values.count)
        for index in 0..<values.count {
            pointer[index] = self.float16BitPattern(from: values[index])
        }
        return array
    }

    nonisolated func float16BitPattern(from value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        var exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        var mantissa = bits & 0x007F_FFFF

        if exponent <= 0 {
            if exponent < -10 {
                return sign
            }
            mantissa |= 0x0080_0000
            let shift = UInt32(14 - exponent)
            let rounded = (mantissa >> shift) + ((mantissa >> (shift - 1)) & 1)
            return sign | UInt16(rounded)
        }

        if exponent >= 0x1F {
            return sign | 0x7C00
        }

        mantissa = mantissa + 0x0000_1000
        if (mantissa & 0x0080_0000) != 0 {
            mantissa = 0
            exponent += 1
            if exponent >= 0x1F {
                return sign | 0x7C00
            }
        }

        return sign | UInt16(exponent << 10) | UInt16(mantissa >> 13)
    }

    nonisolated func makeIntArray(shape: [Int], values: [Int32]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map(NSNumber.init), dataType: .int32)
        let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: values.count)
        _ = values.withUnsafeBufferPointer { buffer in
            memcpy(pointer, buffer.baseAddress, values.count * MemoryLayout<Int32>.stride)
        }
        return array
    }
}

@available(macOS 15, iOS 18, *)
final class FastFeatureProvider: MLFeatureProvider {
    private var values: [String: MLFeatureValue]
    let featureNames: Set<String>

    init(_ pairs: [(String, MLMultiArray)]) {
        var values = [String: MLFeatureValue]()
        values.reserveCapacity(pairs.count)
        var names = Set<String>()
        names.reserveCapacity(pairs.count)

        for (name, array) in pairs {
            values[name] = MLFeatureValue(multiArray: array)
            names.insert(name)
        }

        self.values = values
        self.featureNames = names
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        self.values[featureName]
    }

    func update(_ name: String, _ array: MLMultiArray) {
        self.values[name] = MLFeatureValue(multiArray: array)
    }
}

#endif
