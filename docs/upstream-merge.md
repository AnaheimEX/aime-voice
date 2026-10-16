# 与上游合并

本地只有一条长期分支 `main`。它跟踪 `origin/main`（`zoolapp/aime`），并用合并把上游新版本接进来。语音输入只存在于这条分支上，上游仓库没有这块模块。不要把这条分支推回 `zoolapp/aime`。

## 两边各拥有什么

上游拥有输入法本身：拼音、Caps Lock、粘贴、标点、快捷键、AI 请求体，以及这些功能所在的应用和 `AIMECore` 代码。

分支拥有语音模块，目录固定为：

- `Packages/AIMEKit/Sources/AIMEVoice`
- `Packages/AIMEKit/Sources/AIMEVoiceHost`
- `Packages/AIMEKit/Sources/AIMEVoiceSettings`
- `Packages/AIMEKit/Sources/FluidCaptureSupport`
- `Apps/AIMEVoiceService`
- `scripts/tests` 里的语音检查，以及 `scripts/check-voice-seam.sh`

这些路径上游没有同名文件。合并时它们整段保留，不需要手工挑选。

分支还在少数上游文件里留了接入点。语音不复制一套按键循环，只在现有入口上多问一句。下一次合并若这些文件冲突，采用上游的输入法逻辑，再把接入点放回去。不要用分支的旧文件盖掉上游。

## 接入点

`Apps/AIME/AIMEInputController.swift`

- 引入 `AIMEVoiceHost`，控制器持有 `let voiceOwner = InputOwner()`。
- `activate` 在会话准备之后调用 `engine.voiceFeature.activate(voiceOwner)`。
- `deactivateServer` 在取消润色之后、提交未完成输入之前调用 `engine.voiceFeature.deactivate(this.voiceOwner)`。上游自己的收尾，例如 Caps Lock 回退，保持原样。
- `recognizedEvents` 在上游的事件掩码上增加 `.keyUp`。
- `handle` 在设置 `engine.activeController` 之后、任何输入法按键处理之前调用 `engine.voiceFeature.handle(event, owner: voiceOwner)`。返回 `.consumed` 时取消修饰键单击并返回 `true`。没有被语音吃掉的键继续走上游。

`Apps/AIME/InputEngine.swift`

- 引入 `AIMEVoiceHost`，用 `lazy var voiceFeature = VoiceFeature(host: LocalVoiceAdapter(engine: self))`。
- `start()` 里读取一次 `voiceFeature`，让它在输入法启动时建立。
- `showStatus(_:persistent:)` 保留 `persistent`。持久状态不自动消失。

`Packages/AIMEKit/Package.swift` 声明 `AIMEVoice`、`AIMEVoiceHost`、`AIMEVoiceSettings`。`project.yml` 保留 `AIME Voice` 这个 XPC target，主应用依赖 `AIMEVoiceHost`，设置应用依赖 `AIMEVoiceSettings`。`Apps/AIMESettings/Views/RootView.swift` 保留「语音输入」页。

## 每次合并

工作区必须是干净的。在 `aime` 仓库里：

```bash
git fetch origin
git merge origin/main
scripts/check-voice-seam.sh
```

`git merge` 只在有冲突时停下来。先看冲突是不是接入点文件。是的话，保留上游版本，再按上面的接入点补回语音调用。然后：

```bash
git add <冲突文件>
scripts/check-voice-seam.sh
git merge --continue
```

检查脚本确认接入点还在，并且语音目录没有被删。它不证明输入法新功能和语音可以一起编译。接入点补完后，按当时的发布方式构建一次输入法。

没有冲突时也要跑检查脚本。上游不会主动删除语音目录，但接入点可能在一次自动合并里被带丢。

不要用 rebase 改写已经合并过的提交，不要把语音分支推到上游，也不要在脏工作区里合并。中途想放弃这次合并时，用 `git merge --abort`。
