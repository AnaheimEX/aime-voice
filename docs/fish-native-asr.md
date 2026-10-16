# Fish原生STT接入

更新日期：2026-10-14。当前使用 Fish 官方原生接口，自 Build55 接入并保留于 Build56。Fish Realtime 实现已撤回，不提供流式上传。完整部署状态见[当前进度](voice-module-implementation.md)。

## 请求与结果

- `POST https://api.fish.audio/v1/asr`，Bearer鉴权，模型通过`model`请求头选择，默认`transcribe-1-pro`。
- Multipart上传完整WAV，字段名`audio`；不使用兼容接口的`file`字段或表单`model`。
- `ignore_timestamps=true`；Pro额外发送`tag_audio_events=false`和`diarize=false`。基础模型不携带Pro专属参数。
- 不发送`language`，由服务自动识别。不发送官网未支持的热词参数；现有本地词典替换和后续润色流程不变。
- `diarize=false`不会移除正文中的说话人标记，客户端只移除明确的`<|speaker:N|>`标记，不泛化删除方括号内的用户文字。
- 对401/403、402、429及音频格式错误提供明确提示，不回显服务端任意错误正文，不自动重试导致重复请求。

原生接口整段上传后返回全文；本接入不提供边说边返回半句文本。录音结束后完成ASR，再进入原有润色和上屏流程。

## 旧配置兼容

保留预设ID `fish`和原API Key。加载或恢复旧Fish配置时，在内存中将兼容接口地址迁移到原生地址，并将旧默认`fish-audio/transcribe-1`模型映射到`transcribe-1-pro`。已经明确填写的`transcribe-1`保持不变。迁移不主动改写磁盘配置，正常保存时使用新配置。

原生接口使用固定文档模型，不调用OpenAI兼容`/models`，设置页提供两个官方模型的固定选择项，不显示模型拉取按钮。

## 验证

既有本机服务测试扩展后共18次请求通过，覆盖Pro/基础模型的请求头与上传字段、自动语言、说话人标记清理、401/402、服务配置与密钥隔离、请求取消、HTTP绝对超时和重定向拦截。完整App编译通过。

使用用户此前授权中剩余的1次短音频额度，向官方原生接口发送现有3.8144375秒测试WAV，经应用公开识别入口返回：

> 你好，语音测试。Hello, voice test.

本次从提交识别到得到文本为1152毫秒，包含上传和服务处理，不包含录音、润色或实际上屏；这是单次结果，不是平均或高分位性能承诺。测试未启动麦克风，未调用其他模型，密钥未输出或导出。

## 官方依据

- [STT功能说明](https://docs.fish.audio/features/speech-to-text)
- [原生接口参考](https://docs.fish.audio/api-reference/endpoint/openapi-v1/speech-to-text)

上述验证为接入时的既有记录，本次文档整理未重新执行。真人录音、润色及跨 App 上屏仍待验收。
