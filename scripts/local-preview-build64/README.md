# 本机 Preview 部署源码

这些文件最初从 Build64 临时部署目录迁入；目录名保留，组装和安装入口已在 Build65 交付时参数化。最新完整签名产物为研究项目根目录的 `dist/Build69/AIME Voice Preview.app`，安装位置为 `~/Library/Input Methods/AIME Voice Preview.app`。Build68 产物、签名临时文件和安装回退包已删除。`stage.py` 给 CLI 加上 `@executable_path/../Frameworks`，`sign-nested.py` 给 CLI 关闭 library validation，否则 `Contents/Helpers/aime` 加载不到 `librime.1.dylib`。

## 文件

- `stage.py ROOT PRODUCTS REFERENCE DESTINATION CLI --build NUMBER`：复制 Xcode 主程序、设置、语音服务及 SwiftPM CLI，沿用参考包的词库资源和输入源标识；要求三个组件版本与指定版本一致。目标必须不存在。
- `sign-nested.py APP`：恢复 CTranscribe framework 的版本链接，签署 framework、dylib、CLI 资源包和 CLI。Xcode 可能只重签顶层二进制；若与版本副本不同，先在临时副本按架构统一临时签名，逐字节比较，确认代码一致后才规范布局。移出的重复文件暂存于候选包同级目录，成功交付后清理。
- `sign-local.py APP REFERENCE ROOT`：沿用原本机证书，逐一验证三个原 designated requirements；设置及 XPC 使用已安装 Preview 同样的 library validation 豁免，主程序读取源码已有 entitlements。最终执行完整包 `codesign --verify --deep --strict`。签名需符合当次授权；不会枚举或导出密钥。
- `input-source.swift`：提供 current、select、register；部署前编译为 `input-source`。
- `install.py APP --helper INPUT_SOURCE --work WORK`：要求数值构建号递增，验证候选签名，保存并切换输入源，停止已安装 Preview 进程，将旧包临时移至工作目录，复制／验证／注册新包；失败恢复旧包，成功恢复原输入源并启动主程序与设置。安装后旧包是否保留依用户授权处理。

Build69 的 Xcode 应用使用 Release、`ONLY_ACTIVE_ARCH=NO`、`CURRENT_PROJECT_VERSION=69` 和临时 ad-hoc 签名构建，最终由上述脚本替换成本机证书签名。营销版本来自 `project.yml` 的 0.1.9。CLI 使用 native SwiftPM Release 的 arm64 产物。完整交付结果见 `docs/voice-module-implementation.md`。这些入口不会自动下载语音模型或更改用户语音配置。
