# 与上游同步

本地只有一条长期分支 `main`。上游是 `origin/main`（`zoolapp/aime`）。与上游同步只做拉取和合并，用来保持输入法是最新版本。不要把这条分支推回上游。

语音模块只存在于本地。它不参与上游合并，也不进入上游仓库。语音代码的修改是本地重构，单独提交。一次提交里不要同时改语音模块和上游拥有的输入法逻辑。

## 语音模块

这些路径整段属于本地，上游没有同名实现：

- `Packages/AIMEKit/Sources/AIMEVoice`
- `Packages/AIMEKit/Sources/AIMEVoiceHost`
- `Packages/AIMEKit/Sources/AIMEVoiceSettings`
- `Packages/AIMEKit/Sources/FluidCaptureSupport`
- `Packages/AIMEKit/Tests/AIMEVoiceSettingsTests`
- `Apps/AIMEVoiceService`
- `Apps/AIME/LocalVoiceAdapter.swift`

同步时不打开这些文件，不挑选里面的行，也不把它们的内容和上游做三方合并。上游以后若添了同名路径，保留本地文件。

输入法要调用语音时，只经过 `LocalVoiceAdapter` 和下面列出的接入调用。语音的识别、润色、词库和设置都在语音目录里完成。

## 接入调用

接入调用不是语音模块的代码。它们是本地输入法上的几行调用，让最新的上游按键循环能够碰到语音。上游改写了这些函数时，先整段采用上游的输入法逻辑，再把调用放回原位置。

`Apps/AIME/AIMEInputController.swift`

- 引入 `AIMEVoiceHost`，控制器持有 `let voiceOwner = InputOwner()`。
- `activate` 在会话准备之后调用 `engine.voiceFeature.activate(voiceOwner)`。
- `deactivateServer` 在取消润色之后、提交未完成输入之前调用 `engine.voiceFeature.deactivate(this.voiceOwner)`。上游自己的收尾保持原样。
- `recognizedEvents` 在上游的事件掩码上增加 `.keyUp`。
- `handle` 在设置 `engine.activeController` 之后、任何输入法按键处理之前调用 `engine.voiceFeature.handle(event, owner: voiceOwner)`。返回 `.consumed` 时取消修饰键单击并返回 `true`。其余键继续走上游。

`Apps/AIME/InputEngine.swift`

- 引入 `AIMEVoiceHost`，用 `lazy var voiceFeature = VoiceFeature(host: LocalVoiceAdapter(engine: self))`。
- `start()` 里读取一次 `voiceFeature`。
- `showStatus(_:persistent:)` 保留 `persistent`。

`Packages/AIMEKit/Package.swift` 声明三个语音库。`project.yml` 保留 `AIME Voice` target 和两处 product 依赖。`Apps/AIMESettings/Views/RootView.swift` 保留「语音输入」页。这些是本地接线，不是语音实现。

## 同步命令

工作区必须干净。在 `aime` 仓库里只运行：

```bash
scripts/sync-upstream.sh
```

脚本执行 `git fetch origin` 和 `git merge --no-edit origin/main`，然后运行 `scripts/check-voice-seam.sh`。没有冲突时，输入法已经是上游最新版本，语音目录保持原样。

合并因输入法文件冲突停下时，脚本退出，不自动改写冲突。处理顺序是：语音目录和 `LocalVoiceAdapter.swift` 保留本地；其余冲突文件采用上游，再按上一节放回接入调用。然后：

```bash
git add <已处理的文件>
scripts/check-voice-seam.sh
git merge --continue
```

检查脚本只确认语音目录还在、接入调用还在。它不编译输入法。接入调用有改动时，再按当时的发布方式构建。

不要 rebase 已经同步过的合并提交。不要在脏工作区里同步。放弃本次同步用 `git merge --abort`。
