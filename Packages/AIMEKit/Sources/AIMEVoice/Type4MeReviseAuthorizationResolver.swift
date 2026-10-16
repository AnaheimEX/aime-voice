// Adapted from Type4MeReviseCore/ReviseAuthorizationResolver.swift, commit e24dfda.
// Source: https://github.com/joewongjc/type4me/blob/e24dfda/Type4MeReviseCore/ReviseAuthorizationResolver.swift
// Copyright (c) 2026 Type4Me Contributors
// SPDX-License-Identifier: MIT
// Full license: licenses/type4me.LICENSE.txt (repository root).
// AIME adaptation: public Foundation import for AIME strict Swift settings.

public import Foundation

public enum ReviseAuthorizationDecision: Equatable, Sendable {
    case authorized(ranges: [Range<String.Index>], slotKind: ReviseFactKind?)
    case ambiguous(ReviseRejection)
    case unconstrained
}

public enum ReviseAuthorizationResolver {
    public static func resolve(
        target: String,
        instruction: String,
        analysis: ReviseInstructionAnalysis
    ) -> ReviseAuthorizationDecision {
        guard let auth = analysis.replacementAuthorization else {
            return .unconstrained
        }

        switch auth {
        case .explicit(let oldVal, _):
            var ranges: [Range<String.Index>] = []
            var searchStart = target.startIndex
            while searchStart < target.endIndex,
                  let r = target.range(of: oldVal, range: searchStart..<target.endIndex) {
                ranges.append(r)
                searchStart = r.upperBound
            }

            if ranges.isEmpty {
                return .ambiguous(.scopeNotFound)
            }
            if ranges.count == 1 {
                return .authorized(ranges: ranges, slotKind: nil)
            }
            if let ord = analysis.ordinalReferences.first {
                let idx = ord > 0 ? ord - 1 : (ord == -1 ? ranges.count - 1 : -1)
                if idx >= 0 && idx < ranges.count {
                    return .authorized(ranges: [ranges[idx]], slotKind: nil)
                } else {
                    return .ambiguous(.scopeOrdinalOutOfBounds)
                }
            }
            return .ambiguous(.scopeMultipleMatchesWithoutOrdinal)

        case .implicit(_, let slotKind):
            let allTargetFacts = ReviseFactExtractor.extractFacts(in: target)
            var matchingFacts = allTargetFacts.filter { $0.kind == slotKind }

            // If looking for time or number, handle flexible slot matching if exact kind had 0 matches
            if matchingFacts.isEmpty && slotKind == .number {
                // If user said "改成 2", but target has money/time facts containing digits
                matchingFacts = allTargetFacts.filter { $0.kind == .number || $0.kind == .money }
            }

            if matchingFacts.isEmpty {
                return .ambiguous(.scopeNotFound)
            }
            if matchingFacts.count == 1 {
                return .authorized(ranges: [matchingFacts[0].range], slotKind: slotKind)
            }

            if let ord = analysis.ordinalReferences.first {
                let idx = ord > 0 ? ord - 1 : (ord == -1 ? matchingFacts.count - 1 : -1)
                if idx >= 0 && idx < matchingFacts.count {
                    return .authorized(ranges: [matchingFacts[idx].range], slotKind: slotKind)
                } else {
                    return .ambiguous(.scopeOrdinalOutOfBounds)
                }
            }

            return .ambiguous(.implicitReplacementAmbiguous)
        }
    }
}
