import Foundation

/// Uses the actual app request, parser, deadline and shared URLSession, with synthetic labelled texts.
@main struct VoiceLayaEvaluation {
    struct Sample: Decodable { let id: String; let text: String }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5,
              let base = ProcessInfo.processInfo.environment["LAYA_BASE_URL"],
              let key = ProcessInfo.processInfo.environment["LAYA_API_KEY"] else { return }
        var settings = VoiceSettings()
        settings.mode = "polish"
        settings.polishPrompt = VoiceProcessor.joinedChatPolishInstructions
        settings.decisionProtocol = "laya-predict"
        settings.decisionMode = "accelerate"
        settings.decisionBudgetMilliseconds = Int(args[4]) ?? 600
        settings.decision = VoiceEndpoint(baseURL: base, model: "laya", apiKey: key, protocolType: "laya-predict")
        settings.decision.decisionThreshold = Double(args[2]) ?? 0.5
        settings.decision.decisionActionThreshold = Double(args[3]) ?? 0.5
        let lines = try String(contentsOfFile: args[1], encoding: .utf8).split(separator: "\n")
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let sample = try JSONDecoder().decode(Sample.self, from: Data(line.utf8))
            let started = ContinuousClock.now
            var row: [String: Any] = ["id": sample.id]
            do {
                let result = try await VoiceProcessor().testDecision(text: sample.text, settings: settings)
                row["status"] = result.route == "abstain" ? "abstain" : "covered"
                row["route"] = result.route
                row["probability"] = result.probability
                row["confidence"] = result.confidence
                row["need_polish"] = result.probability >= settings.decision.effectiveDecisionThreshold
                row["strategy"] = ["no_edit": "none", "light_edit": "light", "full_edit": "heavy"][result.route]
                if result.route == "abstain" { row["reason"] = "uncertain_or_conflicting" }
            } catch {
                row["status"] = "unavailable"
                row["route"] = "laya_unavailable"
                switch error {
                case VoiceHTTP.Failure.requestRejected(let code, _, _): row["reason"] = "http_\(code)"
                case let value as URLError: row["reason"] = value.code == .timedOut ? "timeout" : "transport"
                default: row["reason"] = "malformed_or_invalid"
                }
            }
            let elapsed = started.duration(to: .now)
            row["elapsed_ms"] = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
