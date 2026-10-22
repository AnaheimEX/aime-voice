# 本机 Preview 构建与部署

目录名沿用最初迁入时的 Build64。安装位置为 `~/Library/Input Methods/AIME Voice Preview.app`，产物在研究项目根目录的 `dist/Build<构建号>/`。这些入口不会自动下载语音模型或更改用户语音配置。

## 一条命令

```bash
scripts/local-preview-build64/build.sh <构建号> [--install]
```

构建号必须是数字，并大于已安装预览的 `CFBundleVersion`。已安装的预览是参考包：词库资源、输入源标识和三个组件的 bundle identifier 都从它读取。新机器上还没有安装时，用 `AIME_PREVIEW_REFERENCE` 指向以前的产物，例如 `AIME_PREVIEW_REFERENCE="../dist/Build71/AIME Voice Preview.app" scripts/local-preview-build64/build.sh 72 --install`。

签名证书是本机登录钥匙串里的自签名证书「AIME Local Code Signing」，SHA1 写在 `sign-nested.py` 和 `sign-local.py` 里。换机器时要么导入原证书，要么新建一张并更新这两处。Xcode 需要先同意许可（`sudo xcodebuild -license accept`）并完成 `xcodebuild -runFirstLaunch`。

1. `xcodegen generate --spec project.local.yml`：上游 `project.yml` 叠加本地语音 target、依赖和 Info.plist 键。上游的 `Apps/*/Info.plist` 不被改写，本地模板写到 `build/local/`。
2. 合并 `Packages/AIMEKit` 与 `Packages/AIMEVoiceKit` 的 `Package.resolved`，写入工程的 workspace，`xcodebuild` 以 `-onlyUsePackageVersionsFromResolvedFile` 只用锁定版本。
3. Xcode Release 构建：`ONLY_ACTIVE_ARCH=NO`、`CURRENT_PROJECT_VERSION=<构建号>`、临时 ad-hoc 签名。营销版本来自上游 `project.yml`。
4. CLI 用 native SwiftPM Release 构建（arm64）。
5. `stage.py`、`sign-nested.py`、`sign-local.py` 组装并签名，然后删除签名过程留在产物旁边的临时文件。
6. 加 `--install` 时编译 `input-source.swift` 并运行 `install.py`。旧包保存为 `dist/Build<构建号>/work/previous-build<旧构建号>.app.zip`，是否删除由用户决定。回退时先停止并移走已安装的预览，再把 zip 解压到 `~/Library/Input Methods`，不要在 `dist` 里解压后双击。

## 文件

- `stage.py ROOT PRODUCTS REFERENCE DESTINATION CLI --build NUMBER`：复制 Xcode 主程序、设置、语音服务及 SwiftPM CLI，沿用参考包的词库资源和输入源标识；要求三个组件版本与指定版本一致，目标必须不存在。三个 bundle id 改为 `….voicepreview…`；各语言 `InfoPlist.strings` 为预览输入源 id 补上与正式 id 相同的名称。CLI 增加 `@executable_path/../Frameworks` rpath，否则加载不到 `librime.1.dylib`。
- `sign-nested.py APP`：恢复 CTranscribe framework 的版本链接，签署 framework、dylib、CLI 资源包和 CLI（CLI 关闭 library validation）。Xcode 可能只重签顶层二进制；若与版本副本不同，先在临时副本按架构统一临时签名，逐字节比较，确认代码一致后才规范布局。
- `sign-local.py APP REFERENCE ROOT`：用本机证书签名，并按参考包的 designated requirement 验证每个组件：identifier 必须一致，证书哈希换成本机证书。设置及 XPC 关闭 library validation；主程序在上游 `AIME.entitlements` 之上追加 `com.apple.security.device.audio-input`。最后执行完整包 `codesign --verify --deep --strict`。签名需符合当次授权；不会枚举或导出密钥。
- `input-source.swift`：提供 current、select、register；安装前编译为 `input-source`。
- `install.py APP --helper INPUT_SOURCE --work WORK`：没有已安装的预览时按首次安装处理，不做版本比较和旧包备份；否则要求数值构建号递增，验证候选签名，保存并切换输入源，停止已安装 Preview 进程，将旧包移至工作目录，复制／验证／注册新包；失败恢复旧包，成功恢复原输入源并启动主程序与设置。暂存副本、回退用的旧包和安装失败的副本都只保留为 `.zip`，`.app` 注销登记后删除；最后列出仍在 LaunchServices 登记的其他同身份副本。`build.sh` 会在 `dist` 放 `.metadata_never_index`，不让 Spotlight 把产物登记成第二份输入法。同一 bundle id 只能有一份 `.app`：不要把它复制到 `/Applications` 或直接双击 zip 解出的副本，否则 `imklaunchagent` 可能连错副本，打字失效。

预览身份在运行时由 `LocalBuildInfo` 从 bundle id 识别：数据目录为 `~/Library/AIME Voice Preview/Rime`，日志为 `~/Library/Logs/AIME Voice Preview`，与正式版 AIME 互不干扰。完整交付记录见 `docs/voice-module-implementation.md`。
