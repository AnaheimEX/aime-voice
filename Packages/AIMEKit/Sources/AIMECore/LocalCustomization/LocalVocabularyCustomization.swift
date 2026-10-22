import Foundation

/// Learnable subscription vocabulary (local customization).
///
/// Upstream `SubscriptionManager.rebuild` writes `aime_online*.txt` and mounts each table
/// read-only (`stabledb`). When the enclosing app opts in (`LocalBuildInfo.customizesVocabulary`),
/// `afterRebuild` post-processes exactly what upstream produced: the same rows are compiled
/// into `aime_online*_dynamic.dict.yaml` with a dependency schema, and each upstream mount is
/// switched to that dictionary with a `userdb`, so selections are learned. Which rows exist,
/// how they are encoded and which schemas get a mount all stay upstream decisions.
///
/// Hooks in `VocabularySubscriptions.swift`: one call at the end of `rebuild`, one signature
/// part in `tableSignature`. Without the opt-in both are no-ops.
enum LocalVocabularyCustomization {
    enum Failure: Error, Equatable {
        case ambiguousPatch(String)
    }

    /// Tests force the customization on or off for one task.
    @TaskLocal static var enabledOverride: Bool? = nil

    static var isEnabled: Bool { enabledOverride ?? LocalBuildInfo.customizesVocabulary }

    static let version = "local-learnable-v1"
    private static let tableKey = SubscriptionManager.tableName
    private static let dependenciesKey = "schema/dependencies/+"
    private static let layouts: [DoublePinyin?] = [nil] + DoublePinyin.allCases

    static func dictionaryName(for layout: DoublePinyin?) -> String {
        dictionaryName(forTable: String(SubscriptionManager.tableFileName(for: layout).dropLast(4)))
    }

    private static func dictionaryName(forTable table: String) -> String {
        table.hasSuffix("_dynamic") ? table : table + "_dynamic"
    }

    private static var dictionaryNames: Set<String> { Set(layouts.map(dictionaryName(for:))) }

    static func ownedFiles() -> [String] {
        layouts.flatMap { ["\(dictionaryName(for: $0)).dict.yaml", "\(dictionaryName(for: $0)).schema.yaml"] }
    }

    // MARK: - Hooks

    /// Appended to the table signature. A missing file or a mount that is not learnable
    /// changes it, so `ensureTables` rebuilds (twice: upstream stores the signature it
    /// computed before rebuilding, and the repaired state then differs from it once).
    static func signaturePart(paths: AIMEPaths, schemas: [String]) -> String? {
        guard isEnabled else { return nil }
        return isInstalled(paths: paths, schemas: schemas) ? version : version + "-repair"
    }

    /// Runs after upstream wrote its tables and mounts.
    static func afterRebuild(paths: AIMEPaths, schemas: [String]) throws {
        guard isEnabled else { return }
        let layers = ConfigLayers(paths: paths)
        let schemas = Array(Set(schemas)).sorted()
        // Validate every patch first: an ambiguous one keeps all of upstream's mounts.
        let patches = try schemas.map { schema in
            let patch = try layers.generatedPatch(.schema(schema))
            try validate(patch)
            return (schema: schema, patch: patch)
        }
        for layout in layouts {
            let table = paths.userDataDir.appendingPathComponent(SubscriptionManager.tableFileName(for: layout))
            let rows = rows(ofTable: try String(contentsOf: table, encoding: .utf8))
            let dictionary = dictionaryName(for: layout)
            try write(dictionaryFile(dictionary, rows: rows), to: paths.userDataDir.appendingPathComponent("\(dictionary).dict.yaml"))
            try write(dependencySchema(dictionary), to: paths.userDataDir.appendingPathComponent("\(dictionary).schema.yaml"))
        }
        for (schema, patch) in patches where learnable(patch) != patch {
            try layers.updateGenerated(.schema(schema)) { $0 = learnable($0) }
        }
    }

    // MARK: - Transformation

    static func isInstalled(paths: AIMEPaths, schemas: [String]) -> Bool {
        let fm = FileManager.default
        guard ownedFiles().allSatisfy({ fm.fileExists(atPath: paths.userDataDir.appendingPathComponent($0).path) }) else {
            return false
        }
        let layers = ConfigLayers(paths: paths)
        return schemas.allSatisfy { schema in
            guard let patch = try? layers.generatedPatch(.schema(schema)), (try? validate(patch)) != nil else { return false }
            return learnable(patch) == patch
        }
    }

    static func validate(_ patch: [ConfigValue.Entry]) throws {
        let mounts = patch.filter { $0.key == tableKey }
        guard mounts.count <= 1, mounts.allSatisfy({ $0.value.entries != nil }) else {
            throw Failure.ambiguousPatch(tableKey)
        }
        let dependencies = patch.filter { $0.key == dependenciesKey }
        guard dependencies.count <= 1, dependencies.allSatisfy({ $0.value.listValue != nil }) else {
            throw Failure.ambiguousPatch(dependenciesKey)
        }
    }

    /// Idempotent. Mounted schemas get the learnable dictionary and its dependency;
    /// schemas upstream did not mount lose only this module's dependencies.
    static func learnable(_ patch: [ConfigValue.Entry]) -> [ConfigValue.Entry] {
        var result = patch
        var dependency: ConfigValue?
        if let index = result.firstIndex(where: { $0.key == tableKey }),
           let mount = result[index].value.entries,
           let table = result[index].value["user_dict"]?.stringValue, !table.isEmpty {
            let dictionary = dictionaryName(forTable: table)
            result[index].value = .map(learnableMount(mount, dictionary: dictionary))
            dependency = .string(dictionary)
        }
        let names = dictionaryNames
        let index = result.firstIndex { $0.key == dependenciesKey }
        var list = index.flatMap { result[$0].value.listValue } ?? []
        list.removeAll { names.contains($0.stringValue ?? "") }
        if let dependency { list.append(dependency) }
        switch (index, list.isEmpty) {
        case let (index?, true): result.remove(at: index)
        case let (index?, false): result[index].value = .list(list)
        case (nil, false): result.append(.init(dependenciesKey, .list(list)))
        case (nil, true): break
        }
        return result
    }

    /// Keeps upstream's mount options and order; replaces only the dictionary and learning keys.
    private static func learnableMount(_ mount: [ConfigValue.Entry], dictionary: String) -> [ConfigValue.Entry] {
        let overrides: [String: ConfigValue] = [
            "dictionary": .string(dictionary), "user_dict": .string(dictionary),
            "db_class": "userdb", "enable_user_dict": true, "initial_quality": 1.2,
        ]
        var result = mount.map { entry in overrides[entry.key].map { ConfigValue.Entry(entry.key, $0) } ?? entry }
        if !result.contains(where: { $0.key == "enable_user_dict" }) {
            let position = result.firstIndex { $0.key == "db_class" }.map { $0 + 1 } ?? result.endIndex
            result.insert(.init("enable_user_dict", true), at: position)
        }
        for key in ["dictionary", "user_dict", "db_class", "initial_quality"] where !result.contains(where: { $0.key == key }) {
            result.append(.init(key, overrides[key]!))
        }
        return result
    }

    // MARK: - Files

    /// Upstream table rows (`text<TAB>code<TAB>weight`). Vocabulary parsing skips `#` lines,
    /// so no row starts with `#`.
    static func rows(ofTable table: String) -> [String] {
        table.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func dictionaryFile(_ dictionary: String, rows: [String]) -> String {
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
        return header + "\n" + rows.joined(separator: "\n") + "\n"
    }

    static func dependencySchema(_ dictionary: String) -> String {
        """
        # Dependency schema for the learnable AIME vocabulary.
        schema:
          schema_id: \(dictionary)
          name: AIME 在线词库
          version: "1"
        translator:
          dictionary: \(dictionary)

        """
    }

    /// Unchanged files keep their modification date, so librime does not recompile them.
    private static func write(_ content: String, to url: URL) throws {
        if (try? String(contentsOf: url, encoding: .utf8)) == content { return }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
