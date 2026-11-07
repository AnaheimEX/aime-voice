import Foundation

/// Rejects transcripts that contain no dictation.
///
/// A silent press, a mis-triggered key, or a cough all produce a "transcript"
/// that would otherwise be committed over the user's text.
public enum NonsenseDetector {

    /// Words that a model may emit for noise alone.
    public static let fillerWords: Set<String> = [
        "嗯", "啊", "呃", "哦", "哎", "那个", "就是", "这个",
        "um", "uh", "er", "erm", "hmm", "mm", "m",
    ]

    public static func isNonsense(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let stripped = trimmed.trimmingCharacters(
            in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        )
        if stripped.isEmpty { return true }
        // A single character is still dictation in Chinese ("你", "了", "点"),
        // so there is no length floor; noise words are caught by the filler list.
        if fillerWords.contains(stripped.lowercased()) { return true }
        return false
    }
}
