import Foundation

/// Only generated vocabulary files and mounts; never contains user dictionaries or settings.
public struct VocabularyOverlayPlan: Sendable {
    public let files: [String: String]
    public let entryCount: Int
    public let schemas: [String]
    /// Absent for unsupported layouts: remove only stale mounts owned by this module.
    public let mounts: [String: ConfigValue]
    public let managedPatchKeys: Set<String>
}

/// Host-read state of owned file presence and generated patches. Imported/user layers are not inspected.
/// Content changes in source vocabularies remain tracked by SubscriptionManager's signature.
public struct VocabularyOverlaySnapshot: Sendable {
    public let existingFiles: Set<String>
    public let patches: [String: [ConfigValue.Entry]]

    public init(existingFiles: Set<String>, patches: [String: [ConfigValue.Entry]]) {
        self.existingFiles = existingFiles
        self.patches = patches
    }
}

/// Deterministic customization over the upstream subscription results. No file or network I/O.
public enum LocalVocabularyCustomization {
    static let tableName = "aime_online"

    static func tableFileName(for layout: DoublePinyin?) -> String {
        layout.map { "\(tableName)_\($0.rawValue).txt" } ?? "\(tableName).txt"
    }

    private static func dictionaryName(for layout: DoublePinyin?) -> String {
        String(tableFileName(for: layout).dropLast(4)) + "_dynamic"
    }

    private static var dictionaryNames: Set<String> {
        Set(([nil] + DoublePinyin.allCases.map(Optional.some)).map { dictionaryName(for: $0) })
    }

    private static func translatorConfiguration(for layout: DoublePinyin?) -> ConfigValue {
        let dictionary = dictionaryName(for: layout)
        return .map([
            .init("dictionary", .string(dictionary)), .init("user_dict", .string(dictionary)),
            .init("db_class", "userdb"), .init("enable_user_dict", true),
            .init("enable_completion", false), .init("enable_sentence", false),
            .init("initial_quality", 1.2), .init("comment_format", .list([])),
        ])
    }

    /// Remove only our translator and dictionary dependencies, preserving other patches.
    private static func removeMount(from patch: inout [ConfigValue.Entry]) {
        patch.removeAll { $0.key == tableName }
        let translator = ConfigValue.string("table_translator@\(tableName)")
        for key in ["engine/translators/+", "schema/dependencies/+"] {
            guard let index = patch.firstIndex(where: { $0.key == key }),
                  let list = patch[index].value.listValue else { continue }
            let rest = list.filter { value in
                if key == "engine/translators/+" { return value != translator }
                return !dictionaryNames.contains(value.stringValue ?? "")
            }
            if rest.isEmpty { patch.remove(at: index) } else { patch[index].value = .list(rest) }
        }
    }

    private static func append(_ value: ConfigValue, to key: String, in patch: inout [ConfigValue.Entry]) {
        if let index = patch.firstIndex(where: { $0.key == key }) {
            let existing = patch[index].value.listValue ?? []
            if !existing.contains(value) { patch[index].value = .list(existing + [value]) }
        } else {
            patch.append(.init(key, .list([value])))
        }
    }

    /// Full pinyin schemas and double pinyin layouts AIME can convert to.
    static func canMount(_ schema: String) -> Bool {
        if DoublePinyin.layout(forSchema: schema) != nil { return true }
        let nonPinyin = ["double_pinyin", "t9", "wubi", "cangjie", "stroke", "zhengma", "array", "bopomofo", "jyut"]
        return !nonPinyin.contains { schema.hasPrefix($0) }
    }

    public enum Failure: Error, Equatable {
        case unplannedSchema(String)
        case ambiguousPatch(String)
    }

    private static func validate(_ patch: [ConfigValue.Entry], for schema: String,
                                 using plan: VocabularyOverlayPlan) throws {
        guard plan.schemas.contains(schema) else { throw Failure.unplannedSchema(schema) }
        for key in plan.managedPatchKeys.sorted() {
            let values = patch.filter { $0.key == key }
            guard values.count <= 1 else { throw Failure.ambiguousPatch(key) }
            if key != tableName, let value = values.first?.value, value.listValue == nil {
                throw Failure.ambiguousPatch(key)
            }
        }
    }

    public static func updating(_ patch: [ConfigValue.Entry], for schema: String,
                                using plan: VocabularyOverlayPlan) throws -> [ConfigValue.Entry] {
        try validate(patch, for: schema, using: plan)
        var result = patch
        removeMount(from: &result)
        if let configuration = plan.mounts[schema] {
            result.append(.init(tableName, configuration))
            append(.string("table_translator@\(tableName)"), to: "engine/translators/+", in: &result)
            append(configuration["dictionary"]!, to: "schema/dependencies/+", in: &result)
        }
        return result
    }

    public static func isSatisfied(_ plan: VocabularyOverlayPlan, by snapshot: VocabularyOverlaySnapshot) -> Bool {
        guard Set(plan.files.keys).isSubset(of: snapshot.existingFiles) else { return false }
        return plan.schemas.allSatisfy { schema in
            guard let patch = snapshot.patches[schema] else { return false }
            do { try validate(patch, for: schema, using: plan) } catch { return false }
            let value = ConfigValue.map(patch)
            let translators = (value["engine/translators/+"]?.listValue ?? [])
                .filter { $0 == .string("table_translator@\(tableName)") }
            let dependencies = (value["schema/dependencies/+"]?.listValue ?? [])
                .filter { dictionaryNames.contains($0.stringValue ?? "") }
            guard let configuration = plan.mounts[schema] else {
                return value[tableName] == nil && translators.isEmpty && dependencies.isEmpty
            }
            return value[tableName] == configuration
                && translators == [.string("table_translator@\(tableName)")]
                && dependencies == [configuration["dictionary"]!]
        }
    }

    public static func plan(entries sourceEntries: [VocabularyEntry], schemas: [String]) throws -> VocabularyOverlayPlan {
        // Same word from several sources: keep one row per (text, pinyin), highest weight.
        var seen: [String: Int] = [:]
        var entries: [VocabularyEntry] = []
        for entry in sourceEntries {
            let key = entry.text + "\t" + entry.pinyin
            if let index = seen[key] {
                if entry.weight > entries[index].weight { entries[index] = entry }
            } else {
                seen[key] = entries.count
                entries.append(entry)
            }
        }
        var files: [String: String] = [:]
        let layouts: [DoublePinyin?] = [nil] + DoublePinyin.allCases
        for layout in layouts {
            var rows: [String] = []
            var lines = [
                "# Rime table", "# coding: utf-8", "#@/db_name\t\(Self.tableFileName(for: layout))", "#@/db_type\ttabledb", "#",
                "# Generated by AIME from bundled and subscribed vocabularies — do not edit.", "#", "# 此行之后不能写注释",
            ]
            for entry in entries {
                let isLatin = !entry.pinyin.contains(" ") && !entry.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let code: String? = if isLatin { entry.pinyin }
                    else if let layout { layout.code(forPinyin: entry.pinyin) }
                    else { entry.pinyin.replacingOccurrences(of: " ", with: "") }
                if let code, !code.isEmpty { rows.append("\(entry.text)\t\(code)\t\(entry.weight)") }
            }
            lines += rows
            files[Self.tableFileName(for: layout)] = lines.joined(separator: "\n") + "\n"
            let dictionary = Self.dictionaryName(for: layout)
            let header = """
                # Generated by AIME bundled and subscribed vocabularies — do not edit.
                ---
                name: \(dictionary)
                version: "1"
                sort: by_weight
                use_preset_vocabulary: false
                columns: [text, code, weight]
                ...

                """
            files["\(dictionary).dict.yaml"] = header + "\n" + rows.joined(separator: "\n") + "\n"
            let dependency = """
                # Dependency schema for the learnable AIME vocabulary.
                schema:
                  schema_id: \(dictionary)
                  name: AIME 在线词库
                  version: "1"
                translator:
                  dictionary: \(dictionary)

                """
            files["\(dictionary).schema.yaml"] = dependency
        }
        let schemas = Array(Set(schemas)).sorted()
        let mounts = Dictionary(uniqueKeysWithValues: schemas.filter(canMount).map {
            ($0, translatorConfiguration(for: DoublePinyin.layout(forSchema: $0)))
        })
        return VocabularyOverlayPlan(files: files, entryCount: entries.count, schemas: schemas,
                                     mounts: mounts,
                                     managedPatchKeys: [tableName, "engine/translators/+", "schema/dependencies/+"])
    }
}
