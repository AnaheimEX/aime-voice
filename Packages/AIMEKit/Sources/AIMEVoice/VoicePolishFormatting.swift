import Foundation

/// Local formatting for the built-in, space-separated polish style.
/// Technical spans are deliberately preserved rather than interpreting their punctuation.
public enum VoicePolishFormatting {
    // These are conservative lexical protections, not a complete natural-language or
    // programming-language parser. Code keeps its original whitespace. A URL's trailing
    // prose punctuation is excluded; punctuation inside its path/query is retained.
    private static let protections: [NSRegularExpression] = [
        // Fenced code, including an unfinished fence through the end of the input.
        #"(?ms)^[\t ]*(`{3,}|~{3,})[^\r\n]*(?:\r?\n|$).*?(?:^[\t ]*\1[\t ]*(?=\r?$)|\z)"#,
        // Inline code delimited by matching runs of backticks.
        #"(?<!`)(`+)(?!`)[^\r\n]*?\1(?!`)"#,
        // URLs and email addresses; the final punctuation is handled below.
        #"(?i)\b(?:[a-z][a-z0-9+.-]*://|www\.)[^\s<>\"`，。！？；：、…]+"#,
        #"(?i)[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+"#,
        // Decimals, grouped numbers and times, including next to Chinese words.
        #"(?<![A-Za-z0-9_])\d+(?:[.,:]\d+)+"#,
        // Dotted identifiers, file names, versions and initialisms such as U.S.
        #"(?<![A-Za-z0-9_])[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+"#,
        #"(?<![A-Za-z0-9_])(?:[A-Za-z]\.){2,}"#,
        // Preserve tags, including closing tags and their attributes.
        #"</?[A-Za-z][^<>\r\n]*>"#,
    ].map { pattern in
        // All patterns are constants; a malformed pattern is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let sentencePunctuation = CharacterSet(charactersIn: "，。！？；：、…,.!?;:")
    private static let terminalPunctuation = CharacterSet(charactersIn: "。！？.!?…")

    /// Drop sentence-ending marks from each line. Internal commas, colons and list markers stay.
    public static func withoutTerminalPunctuation(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var value = String(line)
            while let scalar = value.unicodeScalars.last,
                  terminalPunctuation.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                value.unicodeScalars.removeLast()
            }
            return value
        }.joined(separator: "\n")
    }

    /// Remove spaces that sit directly between Han text and an ASCII letter or digit.
    /// Spaces between English words stay. Newlines stay.
    public static func joiningHanBoundaries(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace, !character.isNewline {
                var end = index
                while end < characters.count, characters[end].isWhitespace, !characters[end].isNewline { end += 1 }
                if let previous = output.last, end < characters.count, hanBoundary(previous, characters[end]) {
                    index = end
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func hanBoundary(_ lhs: Character, _ rhs: Character) -> Bool {
        (isHan(lhs) && isASCIIWord(rhs)) || (isASCIIWord(lhs) && isHan(rhs))
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isIdeographic }
    }

    private static func isASCIIWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) }
    }

    public static func spaceSeparated(_ text: String, joiningChineseWords: Bool = false) -> String {
        guard !text.isEmpty else { return "" }
        let source = text as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var protected: [NSRange] = []
        for (index, expression) in protections.enumerated() {
            for match in expression.matches(in: text, range: fullRange) {
                var range = match.range
                if index == 2 {
                    // The punctuation directly following a URL usually belongs to prose.
                    // Keep all punctuation inside the URL (notably ? and :).
                    while range.length > 0,
                          let scalar = UnicodeScalar(source.character(at: NSMaxRange(range) - 1)),
                          sentencePunctuation.contains(scalar) {
                        range.length -= 1
                    }
                }
                if range.length > 0 { protected.append(range) }
            }
        }
        protected.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in protected {
            if let previous = merged.last, range.location <= NSMaxRange(previous) {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else {
                merged.append(range)
            }
        }

        var output = ""
        var pendingSpace = false
        var pendingSentenceBreak = false
        func flushSpace(before next: Character? = nil) {
            if pendingSpace, let last = output.last, !last.isWhitespace {
                let isChineseWordGap = joiningChineseWords && !pendingSentenceBreak
                    && last.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
                    && next?.unicodeScalars.allSatisfy { $0.properties.isIdeographic } == true
                if !isChineseWordGap { output.append(" ") }
            }
            pendingSpace = false
            pendingSentenceBreak = false
        }
        func appendProse(_ range: NSRange) {
            for character in source.substring(with: range) {
                if character.isNewline {
                    pendingSpace = false
                    pendingSentenceBreak = false
                    output.append(character)
                } else if character.isWhitespace || character.unicodeScalars.allSatisfy({ sentencePunctuation.contains($0) }) {
                    pendingSpace = true
                    if !character.isWhitespace { pendingSentenceBreak = true }
                } else {
                    flushSpace(before: character)
                    output.append(character)
                }
            }
        }
        var cursor = 0
        for range in merged {
            appendProse(NSRange(location: cursor, length: range.location - cursor))
            flushSpace()
            output.append(source.substring(with: range))
            cursor = NSMaxRange(range)
        }
        appendProse(NSRange(location: cursor, length: source.length - cursor))
        return output
    }
}
