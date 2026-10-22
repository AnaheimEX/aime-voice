import Foundation
import Testing
@testable import AIMECore

/// Local customization only. Upstream's SubscriptionTests run with the customization off.
struct LocalVocabularyCustomizationTests {
    private func workspace() throws -> (root: URL, paths: AIMEPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-local-vocabulary-\(UUID())")
        let paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        try FileManager.default.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.sharedDataDir!.appendingPathComponent("aime"), withIntermediateDirectories: true)
        return (root, paths)
    }

    private func enabled<T>(_ body: () throws -> T) rethrows -> T {
        try LocalVocabularyCustomization.$enabledOverride.withValue(true, operation: body)
    }

    private let learnableFlypy: ConfigValue = .map([
        .init("dictionary", "aime_online_flypy_dynamic"), .init("user_dict", "aime_online_flypy_dynamic"),
        .init("db_class", "userdb"), .init("enable_user_dict", true),
        .init("enable_completion", false), .init("enable_sentence", false),
        .init("initial_quality", 1.2), .init("comment_format", []),
    ])

    @Test func buildInfoDefaultsToUpstreamIdentity() {
        #expect(LocalBuildInfo.identity(from: nil) == .init())
        #expect(LocalBuildInfo.identity(from: ["CFBundleIdentifier": "app.zool.inputmethod.aime"]) == .init())
        #expect(LocalBuildInfo.identity(from: [
            "CFBundleIdentifier": "app.zool.aime.voicepreview.settings", "AIMELocalCustomization": true,
        ]) == .init(isPreview: true, customizesVocabulary: true))
        // The test runner is no local build.
        #expect(LocalBuildInfo.dataFolderName == "AIME")
        #expect(LocalBuildInfo.inputModeID == "app.zool.inputmethod.aime.hans")
        #expect(!LocalBuildInfo.customizesVocabulary)
    }

    @Test func disabledCustomizationLeavesUpstreamOutputAndSignature() throws {
        let (root, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SubscriptionManager(paths: paths)
        try LocalVocabularyCustomization.$enabledOverride.withValue(false) {
            try manager.rebuild(schemas: ["double_pinyin_flypy"])
            #expect(!manager.tableSignature(schemas: ["double_pinyin_flypy"], items: []).contains("local"))
        }
        let layers = ConfigLayers(paths: paths)
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online")?["db_class"] == "stabledb")
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml").path))
        #expect(enabled { manager.tableSignature(schemas: ["double_pinyin_flypy"], items: []) }.hasSuffix("|local-learnable-v1-repair"))
    }

    @Test func rebuildMakesUpstreamMountsLearnableFromUpstreamRows() throws {
        let (root, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "智能体\tzhi neng ti\t95\nDeepSeek\tdeepseek\t95\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"), atomically: true, encoding: .utf8)
        let layers = ConfigLayers(paths: paths)
        try layers.setGenerated(.schema("rime_ice"), keypath: "translator/user_dict", value: "personal_learning")
        try layers.setGenerated(.schema("rime_ice"), keypath: "schema/dependencies/+", value: ["personal"])
        let manager = SubscriptionManager(paths: paths)
        #expect(try enabled { try manager.rebuild(schemas: ["rime_ice", "double_pinyin_flypy", "double_pinyin", "t9"]) } == 2)

        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online") == learnableFlypy)
        #expect(layers.generatedValue(.schema("double_pinyin"), keypath: "aime_online")?["dictionary"] == "aime_online_ziranma_dynamic")
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "translator/user_dict") == "personal_learning")
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "schema/dependencies/+") == ["personal", "aime_online_dynamic"])
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "engine/translators/+") == ["table_translator@aime_online"])
        #expect(layers.generatedValue(.schema("t9"), keypath: "aime_online") == nil)
        #expect(layers.generatedValue(.schema("t9"), keypath: "schema/dependencies/+") == nil)

        // Rows are upstream's table rows, encoded per layout.
        let upstreamTable = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_flypy.txt"), encoding: .utf8)
        let flypy = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_flypy_dynamic.dict.yaml"), encoding: .utf8)
        #expect(flypy.contains("name: aime_online_flypy_dynamic\n"))
        #expect(flypy.contains("sort: by_weight\nuse_preset_vocabulary: false\ncolumns: [text, code, weight]"))
        #expect(flypy.hasSuffix(LocalVocabularyCustomization.rows(ofTable: upstreamTable).joined(separator: "\n") + "\n"))
        #expect(flypy.contains("智能体\tvingti\t95\nDeepSeek\tdeepseek\t95\n"))
        let dependency = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.schema.yaml"), encoding: .utf8)
        #expect(dependency.contains("schema_id: aime_online_dynamic\n") && dependency.contains("dictionary: aime_online_dynamic\n"))
        #expect(enabled { LocalVocabularyCustomization.isInstalled(paths: paths, schemas: ["rime_ice", "double_pinyin_flypy", "double_pinyin", "t9"]) })
    }

    @Test func learnableIsIdempotentAndKeepsOtherKeys() {
        let upstream: [ConfigValue.Entry] = [
            .init("menu/page_size", 9),
            .init("aime_online/initial_quality", 7.0),
            .init("aime_online", .map([
                .init("dictionary", ""), .init("user_dict", "aime_online_flypy"), .init("db_class", "stabledb"),
                .init("enable_completion", false), .init("enable_sentence", false),
                .init("initial_quality", 6), .init("comment_format", []),
            ])),
            .init("engine/translators/+", ["lua_translator@user", "table_translator@aime_online"]),
            .init("schema/dependencies/+", ["user_dependency", "aime_online_dynamic"]),
        ]
        let learnable = LocalVocabularyCustomization.learnable(upstream)
        let value = ConfigValue.map(learnable)
        #expect(value["aime_online"] == learnableFlypy)
        #expect(value["menu/page_size"] == 9)
        #expect(value["aime_online/initial_quality"] == 7.0)
        #expect(value["engine/translators/+"] == ["lua_translator@user", "table_translator@aime_online"])
        #expect(value["schema/dependencies/+"] == ["user_dependency", "aime_online_flypy_dynamic"])
        #expect(LocalVocabularyCustomization.learnable(learnable) == learnable)

        // Unmounted (or unmountable) schemas lose only this module's dependencies.
        let unmounted = LocalVocabularyCustomization.learnable([
            .init("menu/page_size", 8),
            .init("schema/dependencies/+", ["user_dictionary", "aime_online_dynamic", "aime_online_flypy_dynamic"]),
        ])
        #expect(unmounted == [.init("menu/page_size", 8), .init("schema/dependencies/+", ["user_dictionary"])])
        #expect(LocalVocabularyCustomization.learnable([.init("schema/dependencies/+", ["aime_online_dynamic"])]) == [])
    }

    @Test func ambiguousPatchKeepsUpstreamMounts() throws {
        let (root, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let layers = ConfigLayers(paths: paths)
        try layers.setGenerated(.schema("rime_ice"), keypath: "schema/dependencies/+", value: "user_expression")
        #expect(throws: LocalVocabularyCustomization.Failure.ambiguousPatch("schema/dependencies/+")) {
            try enabled { try SubscriptionManager(paths: paths).rebuild(schemas: ["rime_ice", "double_pinyin_flypy"]) }
        }
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online")?["db_class"] == "stabledb")
        #expect(!FileManager.default.fileExists(atPath: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml").path))
    }

    @Test func ensureTablesRepairsOwnedFilesAndMountsWithoutTouchingUserData() throws {
        let (root, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try "智能体\tzhi neng ti\t95\nGitHub\tgithub\t100\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"), atomically: true, encoding: .utf8)
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n  - schema: t9\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let handWritten = "# personal patch\npatch:\n  menu/page_size: 9\n  translator/dictionary: personal\n"
        try handWritten.write(to: paths.userDataDir.appendingPathComponent("rime_ice.custom.yaml"), atomically: true, encoding: .utf8)
        let personalFiles = [
            "personal.dict.yaml": "---\nname: personal\n...\n自定义\tzi ding yi\t999\n",
            "custom_phrase.txt": "昵称\tnc\t10000\n",
            "aime_online_dynamic.userdb/CURRENT": "learned-full-pinyin",
            "aime_online_flypy_dynamic.userdb/CURRENT": "learned-double-pinyin",
        ]
        for (name, content) in personalFiles {
            let url = paths.userDataDir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let layers = ConfigLayers(paths: paths)
        let manager = SubscriptionManager(paths: paths)
        try enabled {
            #expect(try manager.ensureTables())
            // Upstream stored the signature computed before the first install; one pass settles it.
            #expect(try manager.ensureTables())
            #expect(try manager.ensureTables() == false)
            let dictionary = try Data(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml"))
            #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online") == learnableFlypy)
            // A deleted owned file is restored; the repaired state settles after one more pass.
            for name in ["aime_online_dynamic.dict.yaml", "aime_online_flypy_dynamic.schema.yaml", "aime_online.txt"] {
                try fm.removeItem(at: paths.userDataDir.appendingPathComponent(name))
                #expect(try manager.ensureTables())
                _ = try manager.ensureTables()
                #expect(try manager.ensureTables() == false)
                #expect(try Data(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml")) == dictionary)
            }
            // A deleted generated layer is mounted again, learnable.
            try fm.removeItem(at: layers.generatedURL(.schema("double_pinyin_flypy")))
            #expect(try manager.ensureTables())
            _ = try manager.ensureTables()
            #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online") == learnableFlypy)
            #expect(try manager.ensureTables() == false)
            // Removing the last source empties only generated rows; learned data survives.
            try fm.removeItem(at: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"))
            #expect(try manager.ensureTables())
            let emptied = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml"), encoding: .utf8)
            #expect(!emptied.contains("智能体") && emptied.contains("name: aime_online_dynamic"))
        }
        #expect(try String(contentsOf: layers.importedURL(.schema("rime_ice")), encoding: .utf8) == handWritten)
        for (name, content) in personalFiles {
            #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent(name), encoding: .utf8) == content)
        }
    }
}
