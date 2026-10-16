# FluidVoice 语音前段来源

AIME 的原创 MIT 许可不覆盖这里列出的 GPL 派生源码。包含这些源码的结合程序按 GPL-3.0 条款处理；完整许可见同目录 `fluidvoice.LICENSE.txt`。

## 固定来源

- FluidVoice：<https://github.com/altic-dev/FluidVoice/tree/2ca292d173f0ca6ab11cfb93fb52ace83e82248e>，GPL-3.0。
- FluidAudio：<https://github.com/altic-dev/FluidAudio/tree/eb1e6628998e47022799d305b52c2680d3576801>，Apache-2.0，许可见 `fluidaudio.LICENSE.txt`。
- transcribe-cpp-swift：<https://github.com/altic-dev/transcribe-cpp-swift/tree/a16df2905f9c715344374fd2d8dd97c2712a6d96>，版本 0.1.2，MIT，Copyright (c) 2026 The transcribe.cpp authors，许可见 `transcribe-cpp-swift.LICENSE.txt`。其原生 xcframework 的 URL 和 SHA-256 由上游 Package.swift 固定；预编译包内的传递组件与对应源码仍须纳入发布审计。

## 源码对应关系

| AIME 文件 | 上游来源 | 本地变化 |
| --- | --- | --- |
| `Packages/AIMEKit/Sources/FluidCaptureSupport/CoreAudioCaptureSupport.c` | `Sources/CoreAudioCaptureSupport/CoreAudioCaptureSupport.c` | 原样复制，包含上游原子环形缓冲、采音和诊断函数。 |
| `Packages/AIMEKit/Sources/FluidCaptureSupport/include/CoreAudioCaptureSupport.h` | `Sources/CoreAudioCaptureSupport/include/CoreAudioCaptureSupport.h` | 原样复制。 |
| `Packages/AIMEKit/Sources/AIMEVoice/FluidVoiceCapture.swift` | 适配上述 C API，参考 `Sources/Fluid/Services/DirectCoreAudioInput.swift` | 使用 AIME 的权限和取消代次；工作队列消费环形缓冲，经 AIME 重采样器形成 WAV；设备拓扑变化直接终止当前会话；HAL 停止或销毁失败时保留可能仍被回调引用的 C 内存，并拒绝后续采音。 |
| `Packages/AIMEKit/Sources/AIMEVoice/LocalSpeechRecognizer.swift` | 普通话提示词选择改编自 `Sources/Fluid/Services/ExternalCoreMLTranscriptionProvider.swift`；Whisper 调用参考 `WhisperProvider.swift` | 独立 actor 串行加载与推理；录音开始后由会话后台加载，停录等待同一任务，取消同时终止加载与推理；Cohere 使用普通话 token 和 `.aneSmall`；Whisper 自动语言，短音频补静音；保留 AIME 的任务取消与结果校验。该文件按 GPL-3.0 处理。 |
| `Packages/AIMEKit/Sources/AIMEVoice/CohereRecognitionEngine.swift` | FluidAudio `Sources/FluidAudio/ASR/Cohere/CohereTranscribeAsrManager.swift`，上述固定版本，Apache-2.0 | 保留 Core ML 推理实现；中文初始分段上限 8 秒，在末尾 2 秒寻找低能量切点；未生成 EOS 时递归拆段重识别，最短段仍超限则报错；加入取消检查，改用本地字节解码器；录音开始时对首次或空闲至少 30 秒的编码器执行一次无文本输出的预热，不设周期保温任务。 |
| `Packages/AIMEKit/Sources/AIMEVoice/CohereAudioChunkPlanner.swift` | FluidAudio 同目录 `CohereAudioChunkPlanner.swift`，Apache-2.0 | 原样复制分段及文本拼接算法，添加来源注释；不去重或删除已识别词语。 |
| `Packages/AIMEKit/Sources/AIMEVoice/CohereTokenText.swift` | 从上述 FluidAudio manager 的 token 解码提取，Apache-2.0 | 保留 SentencePiece `<0xXX>` 字节 token，聚合完整 UTF-8 字节后解码，修复中文缺字。 |
| `Packages/AIMEKit/Sources/AIMEVoice/LocalSpeechModels.swift` | 模型选型、文件名和 Hugging Face 仓库地址依据 FluidVoice 模型注册表和 WhisperProvider | AIME 自己管理显式下载、同一提交的文件清单、大小与 Git/SHA-256 校验、临时目录和安装收据；不引入 FluidVoice 的 App 设置或学习数据。 |

## 模型资产

模型在用户点击下载时从 Hugging Face 获取，不随源码或 App 内置。下载时先解析仓库 `main` 的提交 SHA，再固定该 SHA 下载文件；安装收据记录提交、文件、大小和哈希。仓库根目录存在的 `LICENSE`、`LICENSE.md`、`LICENSE.txt`、`NOTICE`、`README.md` 随资产保存。

- Cohere：`BarathwajAnandan/cohere-transcribe-03-2026-CoreML-6bit`，模型 ID `CohereLabs/cohere-transcribe-03-2026`。
- Whisper Small：`handy-computer/whisper-small-gguf`。
- Whisper Large v3 Turbo：`handy-computer/whisper-large-v3-turbo-gguf`。

模型权重和转换产物的条款独立于软件库许可。下载文件的完整性校验不等于模型许可审计或商用分发授权；本次没有下载权重，也没有完成权重或原生二进制传递组件的发布审计。

发布对应源码归档时，须包含以上固定版本及实际解析的传递依赖，不能只沿用旧的 Rime 组件源码清单。
