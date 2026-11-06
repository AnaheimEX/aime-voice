import Foundation

/// Deterministic fast path for restating instructions: the speaker says how the target should read
/// ("把海报发我" for "把海报发给我") instead of giving a command. Pure and conservative: when in doubt
/// it returns nil and the model decides. A candidate is only a heuristic guess, so a validator
/// rejection is swallowed here instead of surfacing as an error.
public enum VoiceRewriteRestatement {
    /// Every tunable lives here so the checkpoint review can read all thresholds in one place.
    enum Limits {
        /// Instruction length (Characters, after trimming whitespace/punctuation) accepted for matching.
        static let minInstructionLength = 4
        static let maxInstructionLength = 80
        /// Longer targets always go to the model.
        static let maxTargetLength = 2000
        /// Smallest accepted edit distance; 0 means the instruction is a verbatim substring, i.e. no change.
        static let minEditDistance = 1
        /// Largest accepted edit distance is max(maxDistanceFloor, m / maxDistanceDivisor).
        static let maxDistanceFloor = 1
        static let maxDistanceDivisor = 4
        /// Cost of one edit in the tie-breaking pass. Must exceed maxInstructionLength so that
        /// "fewer edits" always outranks "more exact matches".
        static let editWeight = 1000
        static let sentenceFinalPunctuation: Set<Character> = ["，", "。", "！", "？", "!", "?", ".", ",", "、", "；", ";", "…"]
        static let sentenceFinalParticles: Set<Character> = ["吧", "啊", "呀", "哦", "喔", "嘛", "呗", "呢", "啦", "咯"]
        /// A change in how many of these appear between window and instruction blocks the fast path.
        static let negationCharacters: Set<Character> = ["不", "没", "别", "无", "非", "未", "勿", "否"]
        /// Digit-like characters, compared as a multiset between window and instruction.
        static let numeralCharacters: Set<Character> = Set("0123456789零〇一二三四五六七八九十百千万亿两半")
    }

    struct Window: Equatable {
        /// Character offsets into the target, end exclusive.
        let start: Int
        let end: Int
        let distance: Int
    }

    /// Validated replacement text, or nil when the model must decide.
    public static func candidate(target: String, instruction: String) -> String? {
        candidate(for: VoiceRewriteEngine.makeRequest(target, instruction: instruction))
    }

    public static func candidate(for request: ReviseRequest) -> String? {
        let target = request.targetText
        let instruction = request.instruction
        guard target.count <= Limits.maxTargetLength else { return nil }
        let base = trimmingBoundary(instruction)
        guard (Limits.minInstructionLength...Limits.maxInstructionLength).contains(base.count) else { return nil }

        let analysis = ReviseInstructionAnalyzer.analyze(instruction, targetText: target)
        guard analysis.likelyIntent == nil,
              analysis.replacementAuthorization == nil,
              !analysis.allowsWholeRewrite,
              !analysis.allowsLanguageChange,
              analysis.ordinalReferences.isEmpty,
              !analysis.hasExternalActionTail,
              !analysis.allowsEmptyResult else { return nil }

        for variant in normalizedVariants(of: base) {
            if let result = candidate(request: request, normalized: variant) { return result }
        }
        return nil
    }

    /// First the instruction as spoken (particle kept), then without trailing particles.
    static func normalizedVariants(of base: String) -> [String] {
        var variants = [base]
        var chars = Array(base)
        while let last = chars.last, Limits.sentenceFinalParticles.contains(last) { chars.removeLast() }
        let stripped = trimmingBoundary(String(chars))
        if stripped != base { variants.append(stripped) }
        return variants
    }

    static func trimmingBoundary(_ text: String) -> String {
        var chars = Substring(text)
        while let last = chars.last, isBoundaryNoise(last) { chars = chars.dropLast() }
        while let first = chars.first, isBoundaryNoise(first) { chars = chars.dropFirst() }
        return String(chars)
    }

    static func isBoundaryNoise(_ character: Character) -> Bool {
        if Limits.sentenceFinalPunctuation.contains(character) { return true }
        return character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }

    private static func candidate(request: ReviseRequest, normalized: String) -> String? {
        let pattern = Array(normalized)
        let text = Array(request.targetText)
        let m = pattern.count
        guard m >= Limits.minInstructionLength, !text.isEmpty,
              let windows = optimalWindows(pattern: pattern, text: text), windows.count == 1,
              let window = bestWindow(pattern: pattern, text: text) else { return nil }
        let maxDistance = max(Limits.maxDistanceFloor, m / Limits.maxDistanceDivisor)
        guard (Limits.minEditDistance...maxDistance).contains(window.distance),
              isUnique(window, pattern: pattern, text: text) else { return nil }

        // The window must not swallow punctuation or whitespace that belongs to the target.
        guard !isBoundaryNoise(text[window.start]), !isBoundaryNoise(text[window.end - 1]) else { return nil }

        let windowText = String(text[window.start..<window.end])
        // Only a pure deletion or a pure insertion is trusted here. A substitution (or a mix) can swap
        // words the protected-fact checks do not see, so the model decides those.
        guard isPureDeletionOrInsertion(from: Array(windowText), to: pattern) else { return nil }
        guard ReviseFactExtractor.tokens(in: windowText) == ReviseFactExtractor.tokens(in: normalized),
              sameCount(of: Limits.negationCharacters, windowText, normalized),
              sameMultiset(of: Limits.numeralCharacters, windowText, normalized),
              occurrenceCount(of: Array(windowText), in: text) == 1 else { return nil }

        let candidate = String(text[..<window.start]) + normalized + String(text[window.end...])
        guard candidate != request.targetText else { return nil }
        let response = ReviseModelResponse(
            intent: .replace,
            scope: ReviseScopeDescriptor(kind: .literal, selector: windowText, ordinal: nil),
            ambiguous: false,
            externalActionRequested: false,
            result: candidate
        )
        let result = ReviseOutputValidator.validate(request: request, response: response)
        guard case .accept = result.decision, result.candidateText == candidate else { return nil }
        return candidate
    }

    // MARK: Approximate matching

    /// Best window for `pattern`: fewest edits, then most exactly matched pattern characters,
    /// then shortest, then earliest. Nil when the text is empty.
    static func bestWindow(pattern: [Character], text: [Character]) -> Window? {
        optimalWindows(pattern: pattern, text: text)?
            .min { ($0.end - $0.start, $0.start) < ($1.end - $1.start, $1.start) }
    }

    /// Every window tied at the best (edits, matches) cost, one per end position. More than one means the
    /// choice between them is arbitrary (e.g. "玩乐" against "玩耍" could leave a stray character), so
    /// `candidate` refuses and lets the model decide; `bestWindow` still orders them deterministically.
    static func optimalWindows(pattern: [Character], text: [Character]) -> [Window]? {
        guard !pattern.isEmpty, !text.isEmpty else { return nil }
        let weighted = sellers(pattern: pattern, text: text, editCost: Limits.editWeight, matchCost: -1)
        guard let minCost = weighted.cost.min() else { return nil }
        let distance = minCost <= 0 ? 0 : (minCost + Limits.editWeight - 1) / Limits.editWeight
        return (0..<weighted.cost.count).compactMap { end in
            let start = weighted.start[end]
            guard weighted.cost[end] == minCost, end > start else { return nil }
            // A window that would swallow target punctuation can never be applied; it must not
            // count as a rival of the real match (e.g. "玩" vs "玩，" when the speaker added "耍").
            guard !isBoundaryNoise(text[start]), !isBoundaryNoise(text[end - 1]) else { return nil }
            return Window(start: start, end: end, distance: distance)
        }
    }

    /// True when no window disjoint from `window` is within the same edit distance.
    static func isUnique(_ window: Window, pattern: [Character], text: [Character]) -> Bool {
        let plain = sellers(pattern: pattern, text: text, editCost: 1, matchCost: 0)
        for end in 0..<plain.cost.count where plain.cost[end] <= window.distance {
            // Either the other window ends before ours starts, or its latest-starting form begins after ours ends.
            if end <= window.start || plain.start[end] >= window.end { return false }
        }
        return true
    }

    /// Sellers semi-global alignment (free start and end in `text`). Per end position it returns the
    /// minimal cost and, among optimal alignments, the latest start (i.e. the shortest window).
    static func sellers(pattern: [Character], text: [Character], editCost: Int, matchCost: Int)
        -> (cost: [Int], start: [Int]) {
        let n = text.count
        var prevCost = [Int](repeating: 0, count: n + 1)
        var prevStart = Array(0...n)
        var curCost = prevCost
        var curStart = prevStart
        for i in 1...pattern.count {
            curCost[0] = i * editCost
            curStart[0] = 0
            for j in 1...n {
                let diag = prevCost[j - 1] + (pattern[i - 1] == text[j - 1] ? matchCost : editCost)
                var bestCost = diag, bestStart = prevStart[j - 1]
                for option in [(prevCost[j] + editCost, prevStart[j]), (curCost[j - 1] + editCost, curStart[j - 1])] {
                    if option.0 < bestCost || (option.0 == bestCost && option.1 > bestStart) {
                        bestCost = option.0; bestStart = option.1
                    }
                }
                curCost[j] = bestCost
                curStart[j] = bestStart
            }
            swap(&prevCost, &curCost)
            swap(&prevStart, &curStart)
        }
        return (prevCost, prevStart)
    }

    // MARK: Guards

    /// True when `to` is `from` with characters only removed, or `from` is `to` with characters only
    /// removed (i.e. one is a proper subsequence of the other).
    static func isPureDeletionOrInsertion(from: [Character], to: [Character]) -> Bool {
        guard from != to else { return false }
        return isSubsequence(to, of: from) || isSubsequence(from, of: to)
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] { index += 1 }
        return index == needle.endIndex
    }

    private static func sameCount(of set: Set<Character>, _ a: String, _ b: String) -> Bool {
        a.filter(set.contains).count == b.filter(set.contains).count
    }

    private static func sameMultiset(of set: Set<Character>, _ a: String, _ b: String) -> Bool {
        a.filter(set.contains).sorted() == b.filter(set.contains).sorted()
    }

    private static func occurrenceCount(of needle: [Character], in haystack: [Character]) -> Int {
        guard !needle.isEmpty, needle.count <= haystack.count else { return 0 }
        var count = 0
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if Array(haystack[start..<start + needle.count]) == needle { count += 1 }
        }
        return count
    }
}
