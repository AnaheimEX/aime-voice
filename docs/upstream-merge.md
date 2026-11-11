# 与上游同步

本地只有一条长期分支 `main`。上游是 `origin/main`（`zoolapp/aime`）。同步只做拉取和合并，不 rebase，不把这条分支推回上游。

本机定制分三层。合并时只有第二层可能冲突，而且每处只有一到几行。

1. **本地文件**：上游没有的文件。合并永远不碰它们。
2. **挂钩**：上游文件里的少量调用行，把上游的流程接到本地模块。白名单见下文和 `scripts/check-local-seam.sh`。
3. **本地构建入口**：`project.local.yml` 和 `scripts/local-preview-build64/`。它们在构建时叠加到上游配置上，上游的 `project.yml`、`Package.swift`、`Info.plist`、entitlements、CI 和文档都保持原样。

## 本地文件

| 路径 | 内容 |
| --- | --- |
| `Packages/AIMEVoiceKit/` | 独立 Swift 包：`AIMEVoice`、`AIMEVoiceHost`、`AIMEVoiceSettings`、`FluidCaptureSupport` 及其测试和依赖锁定。不依赖 AIMEKit 的任何模块。 |
| `Packages/AIMEKit/Sources/AIMECore/LocalCustomization/` | 必须编进 AIMECore 的本地代码：`LocalBuildInfo`（预览身份与定制开关）和 `LocalVocabularyCustomization`（可学习词库）。 |
| `Packages/AIMEKit/Tests/AIMECoreTests/LocalVocabularyCustomizationTests.swift` | 上述两者的测试。上游测试文件不改。 |
| `Local/AIME/`、`Local/AIMESettings/`、`Local/AIMEVoiceService/` | 输入法、设置 App 的本地源码和语音 XPC 服务。由 `project.local.yml` 加入对应 target。 |
| `project.local.yml` | 本地 XcodeGen spec，`include` 上游 `project.yml`。 |
| `scripts/local-preview-build64/`、`scripts/check-local-seam.sh`、`scripts/sync-upstream.sh`、`scripts/local-update.py`、`scripts/tests/` 中的语音检查 | 本地构建、签名、安装和检查。 |
| `.github/workflows/local-voice.yml` | 语音检查。上游 `ci.yml` 不改。 |
| `LOCAL.md`、`docs/` 中的本地文档、`licenses/LOCAL_THIRD_PARTY_NOTICES.md` 及语音许可证 | 本地说明。上游 README、隐私说明和第三方声明不改。 |

上游以后若加了同名路径，保留本地文件，再把上游新文件改名接入。

## 挂钩

挂钩只做调用，不含本地逻辑。上游改写了挂钩所在的函数时，先整段采用上游代码，再把挂钩放回同一位置。

`Apps/AIME/AIMEInputController.swift`

- 引入 `AIMEVoiceHost`，控制器持有 `let voiceOwner = InputOwner()`。
- `activate` 在会话准备之后调用 `engine.voiceFeature.activate(voiceOwner)`。
- `deactivateServer` 在取消润色之后、提交未完成输入之前调用 `engine.voiceFeature.deactivate(this.voiceOwner)`。
- `recognizedEvents` 在上游的事件掩码上增加 `.keyUp`。
- `handle` 在设置 `engine.activeController` 之后、任何输入法按键处理之前调用 `engine.voiceFeature.handle(event, owner: voiceOwner)`。返回 `.consumed` 时取消修饰键单击并返回 `true`。

`Apps/AIME/InputEngine.swift`

- 引入 `AIMEVoiceHost`，`lazy var voiceFeature = VoiceFeature(host: LocalVoiceAdapter(engine: self))`。
- `start()` 第一行读取一次 `voiceFeature`。

`Apps/AIME/AppDelegate.swift`：`applicationWillTerminate` 先调用 `voiceFeature.shutdown()`。

`Apps/AIMESettings/Views/RootView.swift`：`Pane.voice`（标题「语音输入」、图标 `mic`、位于「智能」分组），详情页为 `VoiceSettingsPane`。

`Apps/AIMESettings/Views/OverviewView.swift`：`updateControls` 在 `LocalIntegrationControls.replacesUpdater` 为真时显示本机集成更新入口，否则保持上游的更新控件。

`Apps/AIMESettings/Model/DeployService.swift`、`SettingsModel.swift`：输入法 bundle id 与输入源 id 改读 `LocalBuildInfo.inputMethodBundleID`、`LocalBuildInfo.inputModeID`。

`Packages/AIMEKit/Sources/AIMECore/AIMEPaths.swift`：用户数据和日志目录名改读 `LocalBuildInfo.dataFolderName`。

`Packages/AIMEKit/Sources/AIMECore/VocabularySubscriptions.swift`

- `rebuild(schemas:)` 在返回前调用 `LocalVocabularyCustomization.afterRebuild(paths:schemas:)`。
- `tableSignature` 在返回前追加 `LocalVocabularyCustomization.signaturePart(paths:schemas:)`。不要改上游的签名版本串。

`LocalBuildInfo` 读取所在 App 的 Info.plist。没有 `AIMELocalCustomization` 键、bundle id 不含 `.voicepreview` 时，所有挂钩都返回上游默认值，所以上游测试原样通过。

## 同步命令

工作区必须干净。在 `aime` 仓库里运行：

```bash
scripts/sync-upstream.sh --dry-run   # 只预报冲突，不改任何文件
scripts/sync-upstream.sh
```

脚本开启仓库级 `rerere`，执行 `git fetch origin`，先用 `scripts/seam-hooks.py check-upstream origin/main` 在内存中验证所有挂钩能否干净注入上游最新代码，再用 `git merge-tree` 预演合并，随后执行 `git merge --no-commit origin/main`。无论 git 是否报冲突，脚本都会用 `python3 scripts/seam-hooks.py reapply-from origin/main` 把 9 个挂钩文件**直接重建为「上游新版 + 本地挂钩」**（避免三方合并把挂钩行放错位置），再运行 `scripts/check-local-seam.sh`（内部含剥离挂钩后与上游字节级比对）并提交合并。只有非挂钩文件冲突时才会停下等人工处理。

平时若需单独拆卸或重装这 9 个文件的挂钩：

```bash
python3 scripts/seam-hooks.py strip   # 剥离全部本地挂钩，使 9 个上游文件恢复 100% 原版
python3 scripts/seam-hooks.py apply   # 按锚点幂等注入全部本地挂钩
python3 scripts/seam-hooks.py check   # 校验挂钩完整性及剥离后与上游零差异
```

若上游大幅改写了某个挂钩所在函数的签名导致自动注入停下，处理顺序是：

1. 本地文件保留本地版本。
2. 冲突的上游文件取上游版本：`git checkout --theirs <文件>`。
3. 按上一节把挂钩放回。
4. 检查并继续：

```bash
git add <已处理的文件>
scripts/check-local-seam.sh --build
git merge --continue
```

`check-local-seam.sh` 确认三件事：上游文件只在白名单内有改动；上游目录里的本地文件只在允许的路径；每个挂钩和本地模块都在。加 `--build` 时还会编译两个 Swift 包、跑本地词库与订阅测试，并对本地 Xcode 工程做一次不签名的 Debug 构建。

新增挂钩时，同时更新本文、`check-local-seam.sh` 的白名单和挂钩检查。放弃本次同步用 `git merge --abort`。

## 构建

```bash
scripts/local-preview-build64/build.sh <构建号> --install
```

构建号必须大于已安装预览的 `CFBundleVersion`。流程见 [`scripts/local-preview-build64/README.md`](../scripts/local-preview-build64/README.md)。
