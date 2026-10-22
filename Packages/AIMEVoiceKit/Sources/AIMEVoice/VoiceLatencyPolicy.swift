import Foundation

/// Session-local timing only: no transcripts, credentials or learned vocabulary.
actor VoiceLatencyPolicy {
    struct Plan: Sendable {
        let raceDecision: Bool
        let hedgeDelayMilliseconds: Int?
    }

    private struct Circuit {
        var misses = 0
        var skips = 0

        mutating func admit() -> Bool {
            guard skips == 0 else { skips -= 1; return false }
            return true
        }

        mutating func record(won: Bool) {
            if won { misses = 0; skips = 0 }
            else {
                misses += 1
                if misses >= 3 { skips = 3 }
            }
        }
    }

    private struct History {
        var mainTimes: [Int] = []
        var decision = Circuit()
        var hedge = Circuit()

        var hedgeDelay: Int {
            guard mainTimes.count >= 5 else { return 1800 }
            let sorted = mainTimes.sorted()
            let p90 = sorted[Int(ceil(Double(sorted.count) * 0.9)) - 1]
            return min(4000, max(1200, Int(Double(p90) * 1.25)))
        }
    }

    private var profile = ""
    private var histories: [Int: History] = [:]

    private func bucket(_ length: Int) -> Int { length <= 24 ? 0 : (length <= 100 ? 1 : 2) }

    func plan(profile: String, length: Int, decisionEligible: Bool, hedgeEligible: Bool) -> Plan {
        if self.profile != profile {
            self.profile = profile
            histories.removeAll(keepingCapacity: true)
        }
        let key = bucket(length)
        var history = histories[key, default: History()]
        let raceDecision = decisionEligible && history.decision.admit()
        let hedgeDelay = hedgeEligible && history.hedge.admit() ? history.hedgeDelay : nil
        histories[key] = history
        return Plan(raceDecision: raceDecision, hedgeDelayMilliseconds: hedgeDelay)
    }

    func record(profile: String, length: Int, mainMilliseconds: Int?,
                decisionAttempted: Bool, decisionWon: Bool, hedgeAttempted: Bool, hedgeWon: Bool) {
        guard self.profile == profile else { return }
        let key = bucket(length)
        var history = histories[key, default: History()]
        if let mainMilliseconds {
            history.mainTimes.append(mainMilliseconds)
            if history.mainTimes.count > 12 { history.mainTimes.removeFirst() }
        }
        if decisionAttempted { history.decision.record(won: decisionWon) }
        if hedgeAttempted { history.hedge.record(won: hedgeWon) }
        histories[key] = history
    }
}
