// Extracted from FluidAudio eb1e662, Apache-2.0; local byte decoding repair.
import Foundation

enum CohereTokenText {
    static func decode(_ tokenIDs: [Int32], vocabulary: [String], eos: Int?, pad: Int?) -> String {
        var bytes: [UInt8] = []
        for tokenID in tokenIDs {
            let index = Int(tokenID)
            if index == eos { break }
            guard index != pad, vocabulary.indices.contains(index) else { continue }
            let piece = vocabulary[index]
            // SentencePiece byte fallback tokens are text, not control tokens.
            // Decode their UTF-8 only after reassembling the complete byte stream.
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let byte = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(byte)
            } else if !(piece.hasPrefix("<") && piece.hasSuffix(">")) {
                bytes.append(contentsOf: piece.replacingOccurrences(of: "▁", with: " ").utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
