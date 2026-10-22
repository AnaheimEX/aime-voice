# FluidVoice 语音识别接入评估

日期：2026-10-15。FluidVoice 固定提交 `2ca292d173f0ca6ab11cfb93fb52ace83e82248e`，FluidAudio 固定提交 `eb1e6628998e47022799d305b52c2680d3576801`，transcribe-cpp-swift 固定版本 0.1.2（源码提交 `a16df2905f9c715344374fd2d8dd97c2712a6d96`）。用户已要求替换录音和识别前段，并选定“先接中文识别”；本次已修改源码和依赖声明，没有运行依赖解析、编译、测试、模型下载或部署。

## 结论

**源码已将生产录音切换为 FluidVoice Core Audio 组件，识别切换为 Cohere / Whisper。** AIME 继续持有 XPC 生命周期、权限与取消、润色和决策、最终词典替换、上屏目标校验。这里是源码接入状态；尚无编译或运行结果，不能宣称中文准确率、速度或硬件兼容性已得到验证。[1][2][3]

FluidVoice 的 Swift Package 只声明可执行 App target 和 CoreAudio 支持 target，没有提供独立的 ASR library product。相对而言，FluidAudio 明确提供 Swift Package 的 `FluidAudio` library product，可以直接作为工程依赖。[2][8]

## 与 AIME 的接入边界

AIME 当前链路为：

1. `VoiceRuntime` 管理录音会话、唯一采音所有者和取消。
2. `VoiceRecorder` 使用 `FluidVoiceCapture` 适配上游 C 环形缓冲，输出 16 kHz、单声道 Int16 PCM，停录时排空后形成 `RecordedAudio.wav`。
3. `VoiceRecognitionSession.prepare` 在采音前检查模型文件，`start/append/finish/cancel` 管理会话；`finish` 将完整 WAV 交给 `LocalSpeechRecognizer`，转换为 Float PCM 后在本机执行 Cohere 或 Whisper。当前不提供录音中的逐字预览。
4. `VoiceProcessor.process` 执行润色等文字处理及格式整理，随后统一对最终文字应用语音纠错规则。
5. `AIMEVoiceHost` 校验输入目标并提交结果，不经过 Rime 选词或学词。

本地依据：`Packages/AIMEVoiceKit/Sources/AIMEVoice/VoiceRuntime.swift`、`VoiceRecorder.swift`、`VoiceRecognitionSession.swift`、`VoiceTranscriber.swift`、`VoiceProcessor.swift`，以及 `AIMEVoiceHost/VoiceCommitTarget.swift`。

FluidVoice 的 `TranscriptionProvider` 接口接受 **16 kHz 单声道 Float PCM 数组**，区分 `prepare`、`transcribeStreaming`、`transcribeFinal` 和模型清理；它不是可直接代入 AIME 当前会话接口的类型。需要在识别层转换 Int16 到 Float，并适配准备、增量输入、停止收尾、取消和结果回传。首次模型下载、加载和 CoreML 编译不能阻塞 IMK 按键回调。[3]

直接复制 FluidVoice 的 `ASRService` 会引入其 `ObservableObject` 状态、采音所有权、模型准备、会议会话和词典学习等依赖。`FluidAudioProvider` 本身也读取 `SettingsStore`、发音词典及学习配置；`ASRTranscriptionResult` 包含发音注册和词典学习对齐数据。因此不能把这些文件描述为独立、无状态的纯识别组件。[3][4][5]

## 可选后端

| 后端 | 已核对事实 | 对 AIME 的适用判断 |
| --- | --- | --- |
| Parakeet TDT v3 / v2 | README 列 v3 为 25 种欧洲语言，v2 为英语；本地 Apple Silicon 后端由 FluidAudio 提供。[1][4][7] | 适合英文或其支持语言的可选识别；不适合替代 AIME 中文主识别。 |
| Parakeet Flash | README 列英语和 Apple Silicon；属于不同于多语种模型的低延迟选项。[1] | 中文主场景不推荐。README 的速度描述不等于 AIME 实测结果。 |
| Nemotron Speech 3.5 | README 列约 40 种语言和 Apple Silicon；provider 使用 FluidAudio 的 `NemotronStreamingAsrManager`，区分整段和流式模式，并依赖模型下载与语言设置。[1][6] | 可评估的本地识别候选；本次未进一步核准完整语言清单与中文模型效果，不据此承诺替代中文主识别。 |
| Cohere Transcribe | README 明确列出普通话、英语等 14 种语言；`ExternalCoreMLTranscriptionProvider` 使用 `CohereTranscribeAsrManager`，仅 Apple Silicon 可用，支持整段与预览调用。[1][9] | 与中文需求匹配，可优先比较中文质量。预览实现会选择最近一段音频执行转写，不能等同于原生逐帧流式推理。 |
| Whisper | README 列最多 99 种语言；provider 基于 `TranscribeCpp`，读取模型和语言设置，支持 Apple Silicon 和 Intel。[1][10] | 可作为覆盖面较广的本地方案。当前该 provider 在转写入口要求至少 16,000 个样本，接入时需处理 AIME 支持短录音的差异。 |
| Apple Speech | FluidVoice 与 AIME 都有 Apple 识别入口。[1][11] | 单纯换 App 包装层不能推出识别模型升级；是否采用新的 Apple API 应单独比较。 |

模型体积与速度随选型、量化、设备及版本变化。本次不将 README 的“近乎零延迟”等描述视为独立性能证据，也不将模型推理耗时等同于停录至上屏总耗时。[1][3]

## 许可与功能限制

- FluidVoice 官方仓库声明自 2026-02-23 起使用 **GPLv3**，固定提交的 `LICENSE` 为 GNU GPL Version 3。复制其应用或 provider 源码不能沿用 AIME 原创代码的 MIT 标注；对外分发结合后的作品需要处理相应 GPLv3 源码、许可和通知义务。仓库提到的旧 Apache 版本不能用来覆盖当前新增代码。[1][12]
- 固定提交的 FluidAudio 库为 **Apache-2.0**。直接适配这个底层库与复制 FluidVoice App 源码是不同的许可路径；模型权重、转换产物及其他依赖仍要按所选资产自己的许可核对。[7][8][13]
- **Fluid Intelligence 是单独维护的私有本地 AI 运行时。** 官方明确公开 App 可在不启用它时工作；不能因为 FluidVoice 开源，就声称其全部润色引擎、模型权重和分发权均可取得。它也不属于 ASR 本身。[1]
- FluidVoice README 描述了默认的匿名活动和可选详细统计。AIME 没有因接入识别库而需要引入这些 App 级行为；整套 App 移植与后端适配应区别评估。[1]

## 当前接入与使用

设置 → 语音输入 → 语音识别中选择模型，点击“下载模型”，下载完成后保存设置。旧设置缺少 `localSpeechModel` 时默认 Whisper Small；原润色、决策、词典与旧 ASR 配置不会清空。运行前必须构建并安装本次源码，本次没有执行这些操作。

| 选项 | 识别配置 | 权重约占用 |
| --- | --- | --- |
| Cohere Transcribe 6bit | Apple Silicon，普通话 token，沿用上游 `.aneSmall` 计算分配；底层管理长录音分段 | 1.65 GB，Core ML 编译缓存另外占用 |
| Whisper Small | Apple Silicon 优先 Metal、Intel CPU，自动语言 | 270 MB |
| Whisper Large v3 Turbo | 同上，自动语言 | 886 MB |

模型仅在显式点击时下载到 `~/Library/Application Support/AIME/VoiceModels/`；解析仓库提交后，所有文件均固定到同一提交，以 LFS SHA-256 或 Git blob 哈希校验，并写入安装收据。取消只清理本次暂存目录；已有不完整目标目录不会静默覆盖，界面提示移走后重试。下载进度按完成并校验的文件更新，单个大文件传输期间可能保持不变。

本地加载与推理由独立 actor 串行执行。Build59 起，模型在录音开始后由会话后台加载，停录识别等待同一任务；取消会取消两者，同进程后续请求复用已加载模型。Cohere 首次 Core ML 编译可能较慢。模型未下载时在开启麦克风前失败。Whisper 对 0.1～1 秒录音补静音至一秒，不丢弃原短音频。取消会拒绝旧结果，Whisper 连接原生取消；Cohere 底层正在执行的调用可能需要返回后才释放占用。当前没有添加推理时限，也没有测量峰值内存。

设备流格式、默认设备或存活状态变化终止当前录音；丢包拒绝提交缺音结果。HAL stop / destroy 失败时保留可能仍被实时回调持有的 C 分配并锁止本进程后续采音，需重启语音进程恢复。多独立输入流等上游 C 组件不支持的设备直接提示失败，不自动切回旧 AVCaptureTransport。

原润色、翻译、自定义转换、决策与改写继续使用 AIME；最终词典替换只处理完成格式整理的最终听写文字。当前 Cohere / Whisper 不消费识别热词，已有热词仅保留编辑，不参与本轮识别。Rime 数据、词频与备份边界不变。

没有接入 Parakeet、Nemotron、Fluid Intelligence、FluidVoice 自动词典学习或 App 统计。旧云端/Apple ASR 适配器及相关协议检查仍在源码，正常录音入口和设置试音不再选择它们。现有独立检查脚本同步通过 SwiftPM 构建依赖，再编译原检查；本轮没有运行。

许可打包已加入三个完整许可及[源码来源说明](../licenses/fluidvoice-source.md)。对应源码归档、二进制传递依赖和模型权重许可仍须在发布前补齐审计；不把文件完整性校验视为发布审计。

## 一手来源

1. [FluidVoice README，固定提交](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/README.md)：模型和语言、硬件要求、私有 Fluid Intelligence、统计与许可声明。
2. [FluidVoice Package.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Package.swift)：可执行 target 与依赖固定版本。
3. [TranscriptionProvider.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/TranscriptionProvider.swift)：音频契约、结果类型和生命周期。
4. [FluidAudioProvider.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/FluidAudioProvider.swift)：Parakeet、设置与词典依赖。
5. [ASRService.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/ASRService.swift)：App 级状态、采音和会话管理。
6. [NemotronProvider.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/NemotronProvider.swift)：Nemotron 整段/流式、模型与语言依赖。
7. [FluidAudio README，FluidVoice 实际固定的 fork 提交](https://github.com/altic-dev/FluidAudio/tree/eb1e6628998e47022799d305b52c2680d3576801)：Swift SDK 用法、模型与后端说明。
8. [FluidAudio Package.swift](https://github.com/altic-dev/FluidAudio/blob/eb1e6628998e47022799d305b52c2680d3576801/Package.swift)：library product、Swift 6.0、macOS 14 平台及依赖。
9. [ExternalCoreMLTranscriptionProvider.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/ExternalCoreMLTranscriptionProvider.swift)：Cohere、Apple Silicon、预览和最终推理。
10. [WhisperProvider.swift](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services/WhisperProvider.swift)：TranscribeCpp、模型、语言和最短样本检查。
11. [FluidVoice Services 目录](https://github.com/altic-dev/FluidVoice/tree/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/Sources/Fluid/Services)：AppleSpeechProvider 和 AppleSpeechAnalyzerProvider 等入口；本次没有进一步核查其 Apple API 细节。
12. [FluidVoice LICENSE](https://github.com/altic-dev/FluidVoice/blob/2ca292d173f0ca6ab11cfb93fb52ace83e82248e/LICENSE)：GPLv3。
13. [FluidAudio LICENSE](https://github.com/altic-dev/FluidAudio/blob/eb1e6628998e47022799d305b52c2680d3576801/LICENSE)：Apache-2.0。
