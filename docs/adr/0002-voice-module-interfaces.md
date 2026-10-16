# 以功能模块和少量宿主接入接口隔离本机定制

在现有 AIMEKit 包中保留 `AIMEVoice`，增加负责主程序输入交互的 `AIMEVoiceHost` 与完整设置页的 `AIMEVoiceSettings`；保留现有录音 XPC 进程。上游主程序通过 `VoiceFeature` 和 `LocalVoiceAdapter` 接入，不让语音模块反向依赖上游输入控制器或引擎单例。

词库词频只隔离 `AIMECore` 内的定制增量，本机更新独立为项目命令；不新造词库系统或通用插件框架。这一选择保留当前 IMK 上屏及统一设置体验，代价是仍需维护明确的宿主、词库与打包接入点，不能直接接受官方二进制包或保证任意上游更新零冲突。

语音与词库模块拆分已实施，当前接口、生命周期和数据归属见[模块契约](../voice-module-design.md)。本机更新仍待接通生产安装接口；部署与剩余工作见[当前进度](../voice-module-implementation.md)。
