// Adapted from Type4MeReviseCore/ReviseValidationTrace.swift, commit e24dfda.
// Source: https://github.com/joewongjc/type4me/blob/e24dfda/Type4MeReviseCore/ReviseValidationTrace.swift
// Copyright (c) 2026 Type4Me Contributors
// SPDX-License-Identifier: MIT
// Full license: licenses/type4me.LICENSE.txt (repository root).
// AIME adaptation: public Foundation import for AIME strict Swift settings.

public import Foundation

public struct ReviseValidationTrace: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let intent: ReviseIntent?
    public let scopeKind: ReviseScopeDescriptor.Kind?
    public let targetResolution: String
    public let decision: String
    public let rejection: ReviseRejection?
    public let warnings: [ReviseValidationWarning]
    public let diffHunkCount: Int?
    public let changeRatioBucket: String?
    public let externalActionIgnored: Bool

    public init(
        version: Int = currentVersion,
        intent: ReviseIntent?,
        scopeKind: ReviseScopeDescriptor.Kind?,
        targetResolution: String,
        decision: String,
        rejection: ReviseRejection?,
        warnings: [ReviseValidationWarning],
        diffHunkCount: Int?,
        changeRatioBucket: String?,
        externalActionIgnored: Bool
    ) {
        self.version = version
        self.intent = intent
        self.scopeKind = scopeKind
        self.targetResolution = targetResolution
        self.decision = decision
        self.rejection = rejection
        self.warnings = warnings
        self.diffHunkCount = diffHunkCount
        self.changeRatioBucket = changeRatioBucket
        self.externalActionIgnored = externalActionIgnored
    }

    public static func ratioBucket(_ ratio: Double) -> String {
        switch ratio {
        case ..<0.1: return "<10%"
        case 0.1..<0.25: return "10-25%"
        case 0.25..<0.5: return "25-50%"
        case 0.5..<1.0: return "50-100%"
        default: return ">100%"
        }
    }
}
