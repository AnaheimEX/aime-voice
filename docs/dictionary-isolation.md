# 文字词库与语音词典的隔离边界

核对日期：2026-10-15。本文描述当前源码中的内容归属、管理入口和生效路径。核对方式为静态阅读，未运行测试、构建、录音或部署，也未读取或改写用户实际词条。

## 核对结论

当前实现没有发现文字词库与语音词典共用内容、自动导入、双向同步或互相写入的路径。两者已有独立的数据模型、存储和运行消费者。本次保留这些边界，明确设置入口、界面说明和源码注释，并纠正相关文档中的旧说明；不迁移、清空或合并现有词条。

| 项目 | 文字词库 | 语音词典 |
| --- | --- | --- |
| 用途 | 将键盘编码转换为文字候选，支持候选排序和词频学习 | 为语音识别提供专名提示，并在识别后纠正常见错误 |
| 管理入口 | 设置中的“文字输入”分组：“文字词库”和“自定义短语”；词频通过既有 Rime 功能管理 | 设置 → 语音输入 → 语音词典 → 管理语音词典 |
| 数据结构 | `VocabularyEntry(text, pinyin, weight)`、Rime 词典、短语表和用户词频库 | `VoiceVocabulary.hotwords` 与 `replacements` |
| 内容来源 | 随包词表、用户订阅或安装的 Rime 词表、用户短语、Rime 学习记录 | 用户在语音词典中明确维护的识别词条和纠错规则 |
| 生效阶段 | librime 处理按键、生成候选及学习用户选择时 | 当前 Cohere / Whisper 不使用热词；润色等文字处理及格式整理结束后、上屏前应用纠错 |
| 保存与更新 | Rime 工作目录及配置层；词库更新后按既有流程重建和部署 | `voice-settings.json` 内的 `vocabulary` 字段；应用草稿并保存语音设置，供下一次会话使用 |
| 同步与备份 | 既有 Rime 词频同步及 `.aimebackup` 的文字输入备份 | 不进入既有 Rime 同步或 `.aimebackup`；当前界面没有独立词典导入导出 |

这里的“隔离”指词条内容、存储、管理及生效机制隔离。两者仍属于同一个输入法，共用目标输入框和部分宿主界面；组合输入、焦点校验和快捷键之间的生命周期协调不属于词库共用。

## 文字词库的作用机制

`AIMECore/VocabularySubscriptions.swift` 定义文字词条的文本、编码和权重。`SubscriptionManager.allEntries()` 只合并随包的 `aime/aime_tech.tsv` 与文字词库订阅缓存，不读取 `VoiceSettings` 或语音词典。

`LocalVocabularyCustomization` 将这些词条转换为全拼或双拼词表，生成 `aime_online*` 表、动态词典和依赖方案，并在支持的输入方案中挂载 `table_translator@aime_online`。Rime 使用编码、初始权重及相应用户词频处理键盘候选。Rime 用户词频、候选排序和整句语言模型均不作为 ASR 权重，也不作为语音纠错规则。

默认文字输入工作目录为 `~/Library/AIME/Rime/`。独立预览 App 使用 `~/Library/AIME Voice Preview/Rime/`；`AIME_USER_DIR` 可覆盖文字输入目录。订阅配置和缓存位于该工作目录的 `aime/subscriptions.json` 与 `aime/subscriptions/`，自定义短语由该目录下的短语表管理，学习记录位于相应 `*.userdb`。随包基础词典位于 App 的只读 `SharedSupport`，不需要复制进语音词典。

添加、移除、更新或重建文字词库，只更新上述文字输入数据和 Rime 挂载。不会修改语音设置、语音热词或语音纠错缓存。

## 语音词典的作用机制

语音词典随 `VoiceSettings` 保存在 `~/Library/Application Support/AIME/voice-settings.json` 的 `vocabulary` 字段中。该字段只属于语音功能；不从文字词库、用户短语、输入统计或 Rime 学习记录中填充。默认词典为空，没有词典总开关；语音输入总开关控制语音功能是否启用。

当前主版和预览版沿用同一个语音设置路径；预览版拥有独立 Rime 工作目录，不代表语音设置也按 App 版本分开。这一现有行为不改变文字与语音词典之间的隔离。

### 识别词条

当前生产 `VoiceRecognitionSession` 使用 FluidVoice 对应的 Cohere / Whisper 本地后端，不读取或提交 `hotwords`，也不把词条加入润色提示。已保存词条继续保留、可编辑，最多 500 个，每条最多 80 个字符，但本轮本地识别不承诺热词生效。

旧 Apple Speech、豆包和云端整段识别适配器及其协议检查仍保留在源码；它们不再由正常录音入口或设置页调用。旧适配器中的 `contextualStrings` / `request.corpus.context` 支持不能视为当前本地识别已支持热词。最终本地纠错仍生效，文字词库不参与。

### 纠错规则

`VoiceProcessor.process` 先调用一次 `VoiceVocabulary.apply`，再把替换后的文字交给润色、翻译、自定义转换、决策或仅转写。润色结果不再做第二次替换。因此润色模型看不到尚未替换的触发词；润色若重新写出触发词，或把已经替换的词改成别的说法，都不会再被纠正。

润色模式下，整段去掉首尾空白和句末标点后，如果与某一条已启用纠错触发词完全一致，不论长短，跳过润色和决策，路由为 `dictionary_local`。热词仍只在整段剩下 1–4 个非空白字符且完全一致时走这条直出。句子中只是包含热词或触发词时，继续润色。这一路直接提交该次替换结果，保留其中的标点和换行。翻译和仅转写也会先做这一次替换。语音改写不使用语音词典。

当前规则最多 200 条，每条最多 5 个触发词；每个触发词最多 80 个字符，替换内容最多 500 个字符，可包含多行。匹配忽略大小写，并允许触发词字符之间存在空白；边界保护包含 ASCII 字母和数字，不包含下划线。替换内容按字面处理，不解释 `$1` 等模板符号。

规则按保存顺序执行，同一规则中的触发词也按保存顺序展开；后续匹配会看到前面替换后的文字，因此可能发生连续替换。当前并非“长词优先、单轮不级联”。规则编译缓存在语音模块内部，不与 Rime 词库或词频缓存共用。

例如规则将“吉特哈布”替换为 `GitHub`：识别原文里的“吉特哈布”会先变成 `GitHub`，润色看到的是 `GitHub`。若润色把它写成“代码仓库”，最终上屏就是“代码仓库”。整段本身就是一条纠错触发词时，不论是否超过四字，替换结果直接上屏，不再润色。超过四字的整段热词仍润色。仍须通过既有焦点、选区和客户端校验才能上屏。

## 隔离边界

- **内容不互导**：当前没有从文字词库、短语、用户词频或统计中提取语音热词的入口，也没有将语音词条或纠错结果写回文字词库的入口。旧调研中关于 Rime 短语导入语音词典的设想不属于当前功能。
- **设置各自保存**：文字输入设置由宿主 `SettingsModel` 和 Rime 配置层管理；语音设置由 `VoiceSettingsPane` 和 `VoiceSettings` 管理，使用独立的语音配置变更通知。语音词典编辑草稿应用后仍需“保存设置”。
- **运行消费者各自使用**：三个语音模块 `AIMEVoice`、`AIMEVoiceHost`、`AIMEVoiceSettings` 不依赖 `AIMECore` 或 `RimeKit`；文字词库构建模块也不依赖语音模块。Swift Package 的依赖关系保留这一编译边界。
- **语音上屏不经过 Rime 学词**：普通听写通过 `VoiceCommitTarget` 校验客户端、选区和上下文后直接调用 `IMKTextInput.insertText`，不经过 Rime 编码、选词或用户词频写入。语音改写由自己的目标校验与替换路径处理，也不写入 Rime 词库。
- **没有自动学词联动**：当前不从语音改写、目标应用后续编辑或键盘候选选择中自动更新语音词典。内存中的最近听写来源用于连续改写定位，不是持久词库。
- **同步与恢复不越界**：Rime 同步处理文字输入词频；`BackupManager` 按文字输入工作目录及可选统计目录生成和恢复备份，不包含位于独立 Application Support 路径的语音设置或语音词典。恢复文字备份不会恢复、覆盖或清空语音词典。

用户仍可在两处手动填写相同文字，但两份记录没有共享身份、自动同步或联动删除。相同拼写不代表内容共用。

## 维护入口

- 文字词条模型与订阅：`Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift`。
- 文字词库生成与挂载：`Packages/AIMEKit/Sources/AIMECore/LocalCustomization/LocalVocabularyCustomization.swift`。
- 文字工作目录与备份：`AIMECore/AIMEPaths.swift`、`AIMECore/Backup.swift`。
- 语音词典与持久化：`Packages/AIMEVoiceKit/Sources/AIMEVoice/VoiceVocabulary.swift`、`VoiceSettings.swift`。
- 语音生效路径：`AIMEVoice/VoiceRecognitionSession.swift`、`VoiceTranscriber.swift`、`VoiceProcessor.swift`。
- 独立设置入口：`Apps/AIMESettings/Views/RootView.swift`、`LibraryViews.swift` 与 `AIMEVoiceSettings/VoiceSettingsPane.swift`、`VoiceVocabularyEditor.swift`。
- 语音提交：`Packages/AIMEVoiceKit/Sources/AIMEVoiceHost/VoiceCommitTarget.swift`、`VoiceFeature.swift`。

词典存储路径、匹配顺序和文字词频学习保持原有机制，已有词典无需迁移。语音设置新增 `localSpeechModel` 字段，旧文件缺少该字段时使用 Whisper Small，原润色、决策、旧 ASR 配置与词典保留。新采音及本地识别属于源码变更，未构建或安装到本机 App；详见[FluidVoice 接入记录](fluidvoice-integration-assessment-2026-10-15.md)。
