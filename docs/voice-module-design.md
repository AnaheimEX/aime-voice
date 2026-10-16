# 本机定制模块与接口契约

更新日期：2026-10-14。语音模块拆分已实施并随本机预览部署；本机集成更新仅完成框架与模拟验证。当前部署与剩余工作统一见[当前进度](voice-module-implementation.md)。

前置决定：[内置语音与本机集成更新](adr/0001-local-integrated-voice.md)。保留完整语音体验与词库词频定制增量，跟随上游正式稳定版，在本机手动整合、构建、自签名和安装；冲突或检查失败时停止并保留旧版。

## 模块归属

| 模块 | 职责 | 宿主接入 |
| --- | --- | --- |
| `AIMEVoice` | 录音、识别、模型处理、决策、纯文本改写、语音词典、配置与预设、XPC 请求和事件 | XPC 入口使用 `VoiceRuntime`；不接触输入框、候选面板或 Rime 引擎 |
| `AIMEVoiceHost` | 快捷键、输入会话、焦点与改写目标、提交、最近听写、提示音、状态条、XPC 客户端 | `VoiceFeature` 与 `LocalVoiceAdapter`；依赖 `AIMEVoice`，不依赖上游控制器或引擎单例 |
| `AIMEVoiceSettings` | 完整语音设置、词典编辑、预设切换、模型选择与发现、连接测试 | `VoiceSettingsPane(style:)`；依赖 `AIMEVoice`，不依赖宿主设置 App |
| `LocalVocabularyCustomization` | 可学习词典生成、挂载合并和完整性检查 | 位于 `AIMECore/LocalCustomization`，原订阅管理器调用；不拥有订阅网络与调度 |
| 本机集成更新 | 稳定版本检查、独立源码整合、构建、签名、暂存安装及失败恢复 | `scripts/local-update.py` 和设置入口；不常驻，不读取模型凭据或覆盖用户数据 |

保留现有录音 XPC 进程，不新增音频守护进程、通用插件加载器、远程更新服务器或每个提供方独立的 target。文字词库增量与语音词典分别存储和管理：前者用于 Rime 编码、候选与词频，后者用于语音识别提示，以及润色等处理和格式整理完成后的最终文字替换，没有内容互导或学习联动。具体存储、生效路径及同步备份边界见[文字词库与语音词典隔离说明](dictionary-isolation.md)。

## 输入法接入

`VoiceFeature` 是宿主的完整功能入口，一个输入法进程持有一个实例。宿主调用 `activate(_:)`、`handle(_:owner:)`、`deactivate(_:)` 和 `shutdown()`；构造入口支持 `host`，可选配置路径和内部装配细节以源码为准。

`VoiceHost` 提供两个操作：

```swift
func snapshot(for owner: InputOwner) -> InputSnapshot?
func present(_ effect: HostPresentation, for owner: InputOwner)
```

`InputOwner` 是主线程使用的本机生命周期令牌，不是应用名或窗口标题，也不进入 XPC。`InputSnapshot` 包含 `IMKTextInput` 客户端、`canStart` 和 `canCommit`；所有者由 adapter 在返回快照前核对，不是快照字段。

- 开始条件：活动控制器匹配、目标存在、没有组合输入或草稿，也没有阻止录音的原有润色/快捷菜单状态。
- 提交条件：重新读取活动目标并确认组合输入与草稿允许提交。安全输入、客户端一致性、选区及上下文仍由 Host 核对，不仅凭布尔值上屏。
- `KeyDisposition` 为消费或交还上游；消费后继续取消 modifier-tap，普通键取消语音后仍交还上游。
- `HostPresentation` 只提供状态显示、隐藏候选窗及恢复面板；adapter 核对 owner，拒绝旧会话影响新控制器。录音条、音效和波形由语音 Host 管理。

启动时初始化配置/授权通知一次。激活只更新 owner 并安排非阻塞预热，不在 IMK 激活回调同步读取客户端。键盘处理不执行网络、构建或同步模型请求。准备期间的停止意图、幂等停录和旧事件隔离必须保留。失活取消所属会话，旧 owner 不取消新会话；任务使用开始时的配置快照，退出释放观察者、任务和连接。

## 录音服务

`VoiceRuntime` 的入口为 `init(emit:)`、`warmUp()`、`start(_:)`、`stop(_:)`、`cancel(_:)` 和 `shutdown()`。XPC 入口保留调用者校验、连接寿命和进程事务；复用 `VoiceRequest`、`VoiceEvent` 与 `VoiceServiceProtocol`。

- 接受 start 不代表麦克风已启动，只有实际采音就绪后的 recording 事件表示开始；提示音跟随真实事件。
- 每个连接持有 runtime，全进程至多一个采音所有者。`VoiceRecorder` 使用 FluidVoice 的 Core Audio C 环形缓冲采音，保留 AIME 的 PCM 转换、五分钟限制、缓冲和尾音排空；设备或流格式变化终止当前录音。
- 每个会话至多一个终止结果。停止、取消、断连和错误释放资源，旧任务不能释放新任务设备或连接。
- 模块拆分不改变网络顺序、超时、决策预算或失败策略。模拟采音、识别、处理和时间依赖仅用于内部装配，不扩张宿主接口。

当前生产识别改为 `LocalSpeechRecognizer`：Cohere（普通话、Apple Silicon）或 Whisper（自动语言、Small / Large v3 Turbo），停录后处理完整 WAV。模型按需下载，缺少模型在采音前拒绝；加载和推理在独立 actor 执行，Whisper 会话不并发共享。取消会取消推理任务并拒绝其结果；Cohere 底层调用可能需要返回后才释放推理占用，不宣称硬件立即停止计算。没有导入 Fluid Intelligence。

旧 [Fish](fish-native-asr.md) 协议适配器和检查保留，当前录音入口不再调用。原有 [Laya](laya-local-decision.md) 决策、润色与改写保持独立。完整采音/识别接入与来源见[FluidVoice 记录](fluidvoice-integration-assessment-2026-10-15.md)。

## 设置与数据

`VoiceSettingsPane(style:)` 接收 accent、canvas、card、cardBorder、warning、success 等有限颜色角色，页面布局与交互由模块拥有。测试音频使用 `Bundle.module`；配置使用既有 `VoiceSettings` 路径与保存机制。

预设 ID、通知名、配置键及提供方密钥保持各自归属。配置通知只传“已改变”，不携带凭据或录音。Accessibility 请求由输入法主程序响应，设置 App 的授权不能代替主程序授权。保留词典及替换；热词数据保留但当前 Cohere / Whisper 不消费，界面明确提示。旧 ASR 配置保留、不作为当前生产路由；新增 `localSpeechModel` 独立选择，不重置润色、决策或词典。不恢复已移除的改写学词。

## 词库定制增量

`LocalVocabularyCustomization` 提供 `plan(entries:schemas:)`、`updating(_:for:using:)` 和 `isSatisfied(_:by:)`。生成、挂载与检查使用同一计划，沿用 `VocabularyEntry`、双拼转换和 `ConfigValue`。

上游负责下载、订阅、写文件、配置层和重新部署。定制模块仅返回确定性内容与挂载变化，只修改明确拥有的键和列表项，保留其他 translator、依赖及用户 patch。无法识别布局时失败；保留词典名、user_dict 身份、权重与学习配置，不清空学习库。用户目录数据不属于源码整合产物。

## 更新与维护边界

本机更新合同以[CLI 使用说明](local-update-usage.md)为准，当前 UI 分别提供检查上游、同步重建和回退按钮。不能把已有 UI 或手工安装当作生产更新已接通。

整合必须在独立目录中基于明确提交进行，固定正式稳定版 SHA，不覆盖脏工作树。安装使用固定 bundle/输入源标识、签名身份和数据路径；完整 App 同一构建交付，保留上游资源、依赖与许可证。安装窗口须覆盖录音、识别、润色、改写、待提交、组合输入和未保存设置，并持续持有租约。冲突、构建、签名、空闲或启动检查失败时停止或恢复旧包，不调用 AI 自动解冲突后继续。

回退只恢复 App，不覆盖词典、学习记录、配置或密钥。不可逆数据迁移必须停止并单独评估。官方更新器继续保留官方发行判断、公钥和团队校验，本机入口不能伪装官方发行版。

持续维护的接入点包括：控制器激活/按键/失活、进程启动/退出、设置导航与样式、词库重建与检查、工程和打包。上游改变输入会话、配置或资源结构时须修正接入；模块独立不保证零冲突。
