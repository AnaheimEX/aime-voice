import Foundation

@main struct CohereTokenTextCheck {
    static func main() throws {
        struct Manifest: Decodable { let id_to_token: [String]; let eos_token_id: Int; let pad_token_id: Int }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let vocabulary = manifest.id_to_token
        let expected = "测试项目，电脑鼠标，润色不要删字。"
        var tokens: [Int32] = []
        for character in expected {
            if let index = vocabulary.firstIndex(of: String(character)) {
                tokens.append(Int32(index))
            } else {
                for byte in String(character).utf8 {
                    let token = String(format: "<0x%02X>", byte)
                    guard let index = vocabulary.firstIndex(of: token) else { fatalError("missing byte token") }
                    tokens.append(Int32(index))
                }
            }
        }
        let actual = CohereTokenText.decode(tokens, vocabulary: vocabulary, eos: manifest.eos_token_id, pad: manifest.pad_token_id)
        print("expected=\(expected)\nactual=\(actual)")
        guard actual == expected else { print("FAIL byte tokens dropped Chinese characters"); exit(1) }
        print("PASS Chinese UTF-8 byte fallback roundtrip")
    }
}
