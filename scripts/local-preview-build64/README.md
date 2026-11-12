# 本机 AIME 构建与就地部署

目录名沿用最初迁入时的 Build64。安装位置为 `~/Library/Input Methods/AIME.app`（与上游保持完全一致的 Bundle ID 和包名），不保留多余的临时副本或备份。这些入口不会自动下载语音模型或更改用户语音配置。

## 一条命令

```bash
scripts/local-preview-build64/build.sh <构建号> [--install]
```

构建号必须是数字，并大于已安装包的 `CFBundleVersion`。已安装的 `AIME.app` 是参考包：词库资源从它读取。新机器上还没有安装时，用 `AIME_PREVIEW_REFERENCE` 指向参考产物，例如 `AIME_PREVIEW_REFERENCE="../dist/AIME.app" scripts/local-preview-build64/build.sh 31 --install`。

签名证书是本机登录钥匙串里的自签名证书「AIME Local Code Signing」，SHA1 写在 `sign-nested.py` 和 `sign-local.py` 里。换机器时要么导入原证书，要么新建一张并更新这两处。Xcode 需要先同意许可（`sudo xcodebuild -license accept`）并完成 `xcodebuild -runFirstLaunch`。

1. `xcodegen generate --spec project.local.yml`：上游 `project.yml` 叠加本地语音 target、依赖和 Info.plist 键。上游的 `Apps/*/Info.plist` 不被改写，本地模板写到 `build/local/`。
2. 合并 `Packages/AIMEKit` 与 `Packages/AIMEVoiceKit` 的 `Package.resolved`，写入工程的 workspace，`xcodebuild` 以 `-onlyUsePackageVersionsFromResolvedFile` 只用锁定版本。
3. Xcode Release 构建：`ONLY_ACTIVE_ARCH=NO`、`CURRENT_PROJECT_VERSION=<构建号>`、临时 ad-hoc 签名。营销版本来自上游 `project.yml`。
4. CLI 用 native SwiftPM Release 构建（arm64）。构建完成后立即从 LaunchServices 注销并清理 `DerivedData` 中的中间 `.app`，避免系统索引到重复输入法。
5. `stage.py`、`sign-nested.py`、`sign-local.py` 组装并签名，保持上游原本的三个组件 Bundle ID（`app.zool.inputmethod.aime`、`app.zool.aime.settings`、`app.zool.aime.voice`）和输入源 ID（`app.zool.inputmethod.aime.hans`）。
6. 加 `--install` 时编译 `input-source.swift` 并运行 `install.py`：若存在旧版 `AIME Voice Preview.app` 数据则自动迁移至 `~/Library/AIME/Rime`，注销并移除旧 Preview 包与 TCC 记录，就地替换 `~/Library/Input Methods/AIME.app`，并在安装完成后清理 `dist/Build<构建号>` 临时目录，确保磁盘与 LaunchServices 中仅存在唯一一份 `AIME.app`。

## 文件

- `stage.py ROOT PRODUCTS REFERENCE DESTINATION CLI --build NUMBER`：复制 Xcode 主程序、设置、语音服务及 SwiftPM CLI，沿用参考包的词库资源；要求三个组件版本与指定版本一致，保持上游原本的 bundle id 与输入源标识不变。CLI 增加 `@executable_path/../Frameworks` rpath，否则加载不到 `librime.1.dylib`。
- `sign-nested.py APP`：恢复 CTranscribe framework 的版本链接，签署 framework、dylib、CLI 资源包和 CLI（CLI 关闭 library validation）。Xcode 可能只重签顶层二进制；若与版本副本不同，先在临时副本按架构统一临时签名，逐字节比较，确认代码一致后才规范布局。
- `sign-local.py APP REFERENCE ROOT`：用本机证书签名，并验证每个组件的 designated requirement（保持上游 identifier + 本机证书哈希）。设置及 XPC 关闭 library validation；主程序在上游 `AIME.entitlements` 之上追加 `com.apple.security.device.audio-input`。最后执行完整包 `codesign --verify --deep --strict`。签名需符合当次授权；不会枚举或导出密钥。
- `input-source.swift`：提供 current、select、register、disable；安装前编译为 `input-source`。
- `install.py APP --helper INPUT_SOURCE --work WORK`：验证候选签名，自动迁移旧版 `AIME Voice Preview` Rime 词库并注销清理旧版包与 TCC 权限，停止运行中的 AIME 进程，就地替换 `~/Library/Input Methods/AIME.app` 并注册启用 `app.zool.inputmethod.aime.hans`，最后删除暂存目录。

运行时 `LocalBuildInfo` 识别上游默认 bundle id `app.zool.inputmethod.aime`：数据目录为 `~/Library/AIME/Rime`，日志为 `~/Library/Logs/AIME`，与上游正式版完全一致。完整交付记录见 `docs/voice-module-implementation.md`。
