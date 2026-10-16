# Interfaze 云端 STT 接入

日期：2026-10-15。源码已随 Build60 构建、自签并替换安装到本机预览输入法；主程序及设置已启动。尚未完成真实 API 调用，用户密钥未代填。

使用 `https://api.interfaze.ai/v1/chat/completions`，模型 `interfaze-1`，system 指定 `<task>speech_to_text</task>`，空 JSON Schema，非流式返回。整段 WAV 以 Base64 data URL 直接提交，不创建公开音频网址。请求携带零数据保留及跳过缓存头；零数据保留为供应商提供的能力，未独立验证。

设置增加本地／Interfaze 后端选择和 SecureField 密钥输入。默认仍为本地，不修改现有用户设置。Interfaze 密钥按既有 VoiceSettings 机制存储于权限 0600 的本地配置文件，不嵌入源码、安装包或日志。生产会话只在选择云端后于停录上传；本地后端保留 Build59 的并行加载改动。两者成功后均进入原有润色、决策、最终词典替换和安全上屏流程。

适配器固定官方 HTTPS 地址，拒绝重定向，不存 Cookie、凭据缓存或响应缓存；拒绝非 stop 的完成原因、错误任务名、无效 JSON 和空文本。任务取消传播到 URLSession。不自动回退其他后端，也不自动重试收费请求。

验证：独立编译真实适配器，并执行有效中文结果与四种拒绝情况（截断、缺少结构、空文本、错误任务名），全部通过。配置、会话及 SwiftUI 修改仅完成语法解析，未完成整个模块类型检查或 App 构建。真实调用在发出前被自动审批拒绝，原因是命令中出现明文密钥；未绕过，尚无网络连通性、账户额度或识别质量结论。用户提供的密钥未写入源码或本地配置。

受保护输入可使用本机终端隐藏输入，经标准输入传给既有独立检查程序，不把密钥放入命令参数、脚本或 shell 历史。检查程序：`../dist/.voice57-0N79at/interfaze-check`；固定音频：`Packages/AIMEKit/Sources/AIMEVoiceSettings/Resources/VoiceConnectionTest.wav`。

文档来源：
- https://interfaze.ai/docs/audio/speech-to-text
- https://interfaze.ai/docs/run-tasks
- https://interfaze.ai/docs/api/chat-completion
- https://interfaze.ai/docs/handling-files
- https://interfaze.ai/docs/limits
