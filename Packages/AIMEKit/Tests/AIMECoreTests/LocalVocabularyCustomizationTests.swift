import Foundation
import Testing
import AIMECore

struct LocalVocabularyCustomizationTests {
    @Test func planPreservesDictionaryIdentityAndHighestWeightForEachReading() throws {
        let plan = try LocalVocabularyCustomization.plan(entries: [
            .init(text: "智能体", pinyin: "zhi neng ti", weight: 20),
            .init(text: "DeepSeek", pinyin: "deepseek", weight: 95),
            .init(text: "智能体", pinyin: "zhi neng ti", weight: 95),
            .init(text: "行", pinyin: "xing", weight: 60),
            .init(text: "行", pinyin: "hang", weight: 40),
        ], schemas: ["rime_ice", "double_pinyin_flypy"])
        #expect(plan.entryCount == 4)
        #expect(Set(plan.files.keys) == [
            "aime_online.txt", "aime_online_dynamic.dict.yaml", "aime_online_dynamic.schema.yaml",
            "aime_online_flypy.txt", "aime_online_flypy_dynamic.dict.yaml", "aime_online_flypy_dynamic.schema.yaml",
        ])
        let full = try #require(plan.files["aime_online.txt"])
        #expect(full.contains("#@/db_name\taime_online.txt\n"))
        #expect(full.hasSuffix("智能体\tzhinengti\t95\nDeepSeek\tdeepseek\t95\n行\txing\t60\n行\thang\t40\n"))
        let flypy = try #require(plan.files["aime_online_flypy_dynamic.dict.yaml"])
        #expect(flypy.contains("name: aime_online_flypy_dynamic\n"))
        #expect(flypy.contains("智能体\tvingti\t95\nDeepSeek\tdeepseek\t95\n"))
        #expect(flypy.contains("sort: by_weight\nuse_preset_vocabulary: false\ncolumns: [text, code, weight]"))
        let dependency = try #require(plan.files["aime_online_dynamic.schema.yaml"])
        #expect(dependency.contains("schema_id: aime_online_dynamic\n"))
        #expect(dependency.contains("dictionary: aime_online_dynamic\n"))
    }

    @Test func updatingMigratesOnlyOwnedMountsAndKeepsUserPatches() throws {
        let plan = try LocalVocabularyCustomization.plan(entries: [], schemas: ["double_pinyin_flypy"])
        let original: [ConfigValue.Entry] = [
            .init("menu/page_size", 9),
            .init("translator/dictionary", "user_dictionary"),
            .init("aime_online/initial_quality", 7.0),
            .init("engine/translators/+", ["lua_translator@user", "table_translator@aime_online", "table_translator@aime_online"]),
            .init("schema/dependencies/+", ["user_dependency", "aime_online_dynamic", "aime_online_flypy_dynamic"]),
            .init("aime_online", .map([.init("user_dict", "aime_online_flypy")])),
        ]
        let updated = try LocalVocabularyCustomization.updating(original, for: "double_pinyin_flypy", using: plan)
        let value = ConfigValue.map(updated)
        #expect(value["menu/page_size"] == 9)
        #expect(value["translator/dictionary"] == "user_dictionary")
        #expect(value["aime_online/initial_quality"] == 7.0)
        #expect(value["engine/translators/+"] == ["lua_translator@user", "table_translator@aime_online"])
        #expect(value["schema/dependencies/+"] == ["user_dependency", "aime_online_flypy_dynamic"])
        #expect(value["aime_online"] == .map([
            .init("dictionary", "aime_online_flypy_dynamic"), .init("user_dict", "aime_online_flypy_dynamic"),
            .init("db_class", "userdb"), .init("enable_user_dict", true),
            .init("enable_completion", false), .init("enable_sentence", false),
            .init("initial_quality", 1.2), .init("comment_format", []),
        ]))
        #expect(try LocalVocabularyCustomization.updating(updated, for: "double_pinyin_flypy", using: plan) == updated)
    }

    @Test func updatingRejectsAmbiguousSharedKeysAndUnplannedSchemas() throws {
        let plan = try LocalVocabularyCustomization.plan(entries: [], schemas: ["rime_ice"])
        for patch: [ConfigValue.Entry] in [
            [.init("engine/translators/+", "user_expression")],
            [.init("schema/dependencies/+", .map([.init("__include", "user.yaml")]))],
            [.init("engine/translators/+", []), .init("engine/translators/+", ["user"])],
            [.init("aime_online", .map([])), .init("aime_online", .map([]))],
        ] {
            #expect(throws: (any Error).self) {
                try LocalVocabularyCustomization.updating(patch, for: "rime_ice", using: plan)
            }
        }
        #expect(throws: (any Error).self) {
            try LocalVocabularyCustomization.updating([], for: "not_in_plan", using: plan)
        }
    }

    @Test func satisfactionRequiresEveryOwnedFile() throws {
        let plan = try LocalVocabularyCustomization.plan(entries: [], schemas: ["rime_ice"])
        let patch = try LocalVocabularyCustomization.updating([], for: "rime_ice", using: plan)
        let names = Set(plan.files.keys)
        #expect(LocalVocabularyCustomization.isSatisfied(plan, by: .init(existingFiles: names, patches: ["rime_ice": patch])))
        for name in names {
            #expect(!LocalVocabularyCustomization.isSatisfied(plan, by: .init(existingFiles: names.subtracting([name]), patches: ["rime_ice": patch])))
        }
    }

    @Test func satisfactionDetectsStaleMountsButIgnoresUnrelatedConfiguration() throws {
        let plan = try LocalVocabularyCustomization.plan(entries: [], schemas: ["rime_ice", "t9"])
        let healthy = try LocalVocabularyCustomization.updating([
            .init("menu/page_size", 7), .init("engine/translators/+", ["user_translator"]),
            .init("schema/dependencies/+", ["user_dictionary"]),
            .init("aime_online/initial_quality", 9.0),
        ], for: "rime_ice", using: plan)
        func satisfied(_ full: [ConfigValue.Entry], _ t9: [ConfigValue.Entry] = []) -> Bool {
            LocalVocabularyCustomization.isSatisfied(plan, by: .init(
                existingFiles: Set(plan.files.keys), patches: ["rime_ice": full, "t9": t9]))
        }
        #expect(satisfied(healthy))
        #expect(!satisfied([]))
        #expect(!LocalVocabularyCustomization.isSatisfied(plan, by: .init(existingFiles: Set(plan.files.keys), patches: [:])))
        for key in ["aime_online", "engine/translators/+", "schema/dependencies/+"] {
            #expect(!satisfied(healthy.filter { $0.key != key }))
        }
        var duplicate = healthy
        let translatorIndex = try #require(duplicate.firstIndex { $0.key == "engine/translators/+" })
        duplicate[translatorIndex].value = ["user_translator", "table_translator@aime_online", "table_translator@aime_online"]
        #expect(!satisfied(duplicate))
        var wrongDictionary = healthy
        let dependencyIndex = try #require(wrongDictionary.firstIndex { $0.key == "schema/dependencies/+" })
        wrongDictionary[dependencyIndex].value = ["aime_online_dynamic", "aime_online_flypy_dynamic"]
        #expect(!satisfied(wrongDictionary))
        var noLearning = healthy
        let configIndex = try #require(noLearning.firstIndex { $0.key == "aime_online" })
        var config = noLearning[configIndex].value
        config.set(false, at: "enable_user_dict")
        noLearning[configIndex].value = config
        #expect(!satisfied(noLearning))
        #expect(!satisfied(healthy, [.init("engine/translators/+", ["table_translator@aime_online"])]))
        #expect(!satisfied(healthy, [.init("schema/dependencies/+", ["aime_online_flypy_dynamic"])]))
        #expect(!satisfied(healthy, [.init("aime_online", .map([]))]))
        #expect(!satisfied(healthy + [.init("engine/translators/+", "unknown")]))
    }

    @Test func rebuildRejectsAmbiguousPatchBeforeWritingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-local-vocabulary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AIMEPaths(userDataDir: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layers = ConfigLayers(paths: paths)
        try layers.setGenerated(.schema("z_bad"), keypath: "engine/translators/+", value: "unknown_expression")
        let previousPatch = try Data(contentsOf: layers.generatedURL(.schema("z_bad")))
        let table = root.appendingPathComponent("aime_online.txt")
        try "keep previous table".write(to: table, atomically: true, encoding: .utf8)
        #expect(throws: LocalVocabularyCustomization.Failure.ambiguousPatch("engine/translators/+")) {
            try SubscriptionManager(paths: paths).rebuild(schemas: ["rime_ice", "z_bad"])
        }
        #expect(try String(contentsOf: table, encoding: .utf8) == "keep previous table")
        #expect(try Data(contentsOf: layers.generatedURL(.schema("z_bad"))) == previousPatch)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("aime_online_dynamic.dict.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: layers.generatedURL(.schema("rime_ice")).path))
    }

    @Test func unsupportedSchemasLoseOnlyOwnedMounts() throws {
        for schema in ["double_pinyin_mspy", "t9", "wubi86", "cangjie5", "stroke", "zhengma", "array30", "bopomofo", "jyut6ping3"] {
            let plan = try LocalVocabularyCustomization.plan(entries: [], schemas: [schema])
            #expect(plan.mounts[schema] == nil)
            let patch: [ConfigValue.Entry] = [
                .init("menu/page_size", 8),
                .init("aime_online/initial_quality", 6.0),
                .init("aime_online", .map([.init("dictionary", "aime_online_dynamic")])),
                .init("engine/translators/+", ["user_translator", "table_translator@aime_online"]),
                .init("schema/dependencies/+", ["user_dictionary", "aime_online_dynamic", "aime_online_flypy_dynamic"]),
            ]
            let updated = try LocalVocabularyCustomization.updating(patch, for: schema, using: plan)
            #expect(updated == [
                .init("menu/page_size", 8), .init("aime_online/initial_quality", 6.0),
                .init("engine/translators/+", ["user_translator"]),
                .init("schema/dependencies/+", ["user_dictionary"]),
            ])
            #expect(LocalVocabularyCustomization.isSatisfied(plan, by: .init(existingFiles: Set(plan.files.keys), patches: [schema: updated])))
            #expect(try LocalVocabularyCustomization.updating(updated, for: schema, using: plan) == updated)
        }
    }

    @Test func planIsDeterministicAndDoesNotGuessUnsupportedDoublePinyinCodes() throws {
        let entries: [VocabularyEntry] = [
            .init(text: "未知", pinyin: "not-a-syllable", weight: 80),
            .init(text: "GitHub", pinyin: "github", weight: 123),
        ]
        let plan = try LocalVocabularyCustomization.plan(entries: entries, schemas: ["rime_ice", "rime_ice"])
        let repeated = try LocalVocabularyCustomization.plan(entries: entries, schemas: ["rime_ice"])
        #expect(plan.schemas == ["rime_ice"])
        #expect(plan.files == repeated.files)
        #expect(plan.mounts == repeated.mounts)
        #expect(plan.files["aime_online.txt"]?.contains("未知\tnot-a-syllable\t80\n") == true)
        #expect(plan.files["aime_online_flypy.txt"]?.contains("未知") == false)
        #expect(plan.files["aime_online_flypy.txt"]?.contains("GitHub\tgithub\t123\n") == true)
    }

    @Test func ensureRepairsOwnedFilesAndMountsWithoutTouchingUserData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aime-local-vocabulary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AIMEPaths(userDataDir: root.appendingPathComponent("user"), sharedDataDir: root.appendingPathComponent("shared"))
        let fm = FileManager.default
        try fm.createDirectory(at: paths.userDataDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.sharedDataDir!.appendingPathComponent("aime"), withIntermediateDirectories: true)
        try "智能体\tzhi neng ti\t95\nGitHub\tgithub\t100\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"), atomically: true, encoding: .utf8)
        try "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n  - schema: t9\n".write(
            to: paths.sharedDataDir!.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
        let handWritten = "# personal patch\npatch:\n  menu/page_size: 9\n  translator/dictionary: personal\n"
        try handWritten.write(to: paths.userDataDir.appendingPathComponent("rime_ice.custom.yaml"), atomically: true, encoding: .utf8)
        let personalFiles = [
            "personal.dict.yaml": "---\nname: personal\n...\n自定义\tzi ding yi\t999\n",
            "custom_phrase.txt": "昵称\tnc\t10000\n",
            "default.custom.yaml": "patch:\n  menu/page_size: 6\n",
            "aime_online_dynamic.userdb/CURRENT": "learned-full-pinyin",
            "aime_online_flypy_dynamic.userdb/CURRENT": "learned-double-pinyin",
        ]
        for (name, content) in personalFiles {
            let url = paths.userDataDir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        let layers = ConfigLayers(paths: paths)
        try layers.setGenerated(.schema("rime_ice"), keypath: "engine/translators/+", value: ["user_translator"])
        try layers.setGenerated(.schema("rime_ice"), keypath: "schema/dependencies/+", value: ["personal"])
        try layers.setGenerated(.schema("t9"), keypath: "aime_online", value: .map([]))
        let manager = SubscriptionManager(paths: paths)
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)
        let originalDictionary = try Data(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml"))
        #expect(String(decoding: originalDictionary, as: UTF8.self).contains("智能体\tzhinengti\t95\n"))
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online")?["user_dict"] == "aime_online_flypy_dynamic")
        #expect(layers.generatedValue(.schema("t9"), keypath: "aime_online") == nil)
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "engine/translators/+") == ["user_translator", "table_translator@aime_online"])
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "schema/dependencies/+") == ["personal", "aime_online_dynamic"])
        for name in ["aime_online.txt", "aime_online_dynamic.dict.yaml", "aime_online_dynamic.schema.yaml"] {
            try fm.removeItem(at: paths.userDataDir.appendingPathComponent(name))
            #expect(try manager.ensureTables())
            #expect(try manager.ensureTables() == false)
            #expect(try Data(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml")) == originalDictionary)
        }
        try layers.setGenerated(.schema("rime_ice"), keypath: "schema/dependencies/+", value: ["personal", "aime_online_flypy_dynamic"])
        #expect(try manager.ensureTables())
        #expect(layers.generatedValue(.schema("rime_ice"), keypath: "schema/dependencies/+") == ["personal", "aime_online_dynamic"])
        try fm.removeItem(at: layers.generatedURL(.schema("double_pinyin_flypy")))
        #expect(try manager.ensureTables())
        #expect(layers.generatedValue(.schema("double_pinyin_flypy"), keypath: "aime_online")?["enable_user_dict"] == true)
        #expect(try manager.ensureTables() == false)
        // Removing the last source clears only generated rows, once; learned data survives.
        try fm.removeItem(at: paths.sharedDataDir!.appendingPathComponent("aime/aime_tech.tsv"))
        #expect(try manager.ensureTables())
        #expect(try manager.ensureTables() == false)
        let emptied = try String(contentsOf: paths.userDataDir.appendingPathComponent("aime_online_dynamic.dict.yaml"), encoding: .utf8)
        #expect(!emptied.contains("智能体"))
        #expect(emptied.contains("name: aime_online_dynamic"))
        #expect(try String(contentsOf: layers.importedURL(.schema("rime_ice")), encoding: .utf8) == handWritten)
        #expect(try ConfigValue.map(layers.composedPatch(.schema("rime_ice")))["menu/page_size"] == 9)
        for (name, content) in personalFiles {
            #expect(try String(contentsOf: paths.userDataDir.appendingPathComponent(name), encoding: .utf8) == content)
        }
    }
}
