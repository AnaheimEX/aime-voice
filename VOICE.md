# AIME Voice · 艾么输入法（语音定制版）

> **Fork 说明**：本仓库是 [zoolapp/aime](https://github.com/zoolapp/aime) 的个人定制分支，在上游中文输入法之上**独立叠加**了一套本地语音输入与语音改写模块。
>
> **上游代码保持原样**：本分支不改写上游任何源文件，只新增独立的 Swift Package 与构建入口。上游更新时通过 `git merge` 跟进，不做手工拼改。

[上游 README](README.md) · [文档索引](docs/README.md) · [语音模块设计](docs/voice-module-design.md) · [隐私说明](docs/privacy.md)

---

## 这个 Fork 做了什么

在上游 RIME 输入法的基础上，加了一个**按住说话、松手上屏**的语音层，并支持对着已落屏的文字做二次语音改写。

核心目标：**在中文输入法里做到「说一句 → 润色好的文字直接进输入框」，且尽量少等云端。**

```
按住快捷键 ──► 麦克风采集 ──► ASR 识别 ──► 本地词典纠错 ──► 润色/改写 ──► 安全写入光标处
   (50ms)      (实时 PCM)     (370~550ms)     (≈0ms)        (560~1500ms)      (≈1ms)
```

---

## 功能

### 听写

- **按住说话 / 按一下开始再按一下结束**，两种手势可选
- 胶囊浮层显示三态：**正在识别 → 正在润色 → 完成**，带实时音量波形
- 支持任意快捷键组合（含单修饰键），可自定义取消键（默认 Esc）

### 语音改写

对已经上屏的文字说一句修改指令，直接改掉，不用说「帮我修改」这类废话：

| 口述 | 走哪条路 | 结果 |
| --- | --- | --- |
| 「把发给改成发」 | 显式替换，**本地解析** | 秒出，不调模型 |
| 「把海报发我」（直接说改完的话） | 重述快路径，**本地匹配** | 秒出，不调模型 |
| 「把给字去掉」 | 送一次润色模型 | 模型理解后改 |

重述快路径的守卫（全部满足才本地出结果，否则交模型）：纯删除或纯插入、编辑距离超阈值即拒绝、唯一匹配、数字/否定词数量不变、目标长度上限、与已授权改动范围一致。

### 润色

- 三种模式：`polish`（润色）、`raw`（原样）、`translate`（翻译到指定语言）
- 内置聊天风格提示词；支持完全自定义系统提示词
- 短句直出：短到不需要模型的句子直接本地格式化上屏
- 慢响应对冲（hedge）：长句润色超时后接受一次同模型快速重试，失败保持原文

### 词典与热词

- **热词**：提示 ASR 优先识别指定词（按后端能力下发，不是所有后端都支持）
- **纠错替换**：润色**之前**执行一次，支持多触发词、按序级联、大小写与 ASCII 边界规则
- 整段完全等于一个纠错触发词时，直接上屏，不调模型

### 安全与稳定

| 机制 | 作用 |
| --- | --- |
| `SecureEventInputShield` | 安全输入状态（密码框、锁屏）下**拒绝开麦** |
| `NonsenseDetector` | 拦截 ASR 对噪声凭空生成的「嗯。」「Thank you.」，不把垃圾送上屏 |
| `AudioGain` | 小声说话先归一化再送 ASR；纯静音段直接判定为无语音 |
| `ObjCExceptionCatcher` | 包住所有 `AXUIElementSetAttributeValue`——AX 会抛 ObjC 异常而 Swift 无法捕获，一个坏 App 就能让整个输入法进程退出 |
| `VoiceCommitTarget` | 提交前校验客户端身份、选区、光标前上下文三者未变，否则拒写 |
| `CrashGuard` / `CrashLog` | 自建崩溃日志（默认不挂载，见下） |

---

## 机制要点

### 三层隔离，让上游更新不冲突

```
① 本地文件   Packages/AIMEVoiceKit/  独立 Swift 包，不依赖上游 AIMEKit
             Local/                  XPC 语音服务入口
             project.local.yml       构建入口，用 include 叠加上游 project.yml
             scripts/local-preview-build64/   构建与签名
             scripts/check-local-seam.sh      接缝断言
② 上游挂钩   上游文件里的调用行 —— 当前为零
③ 构建       xcodegen 以 project.local.yml 生成工程
```

`scripts/check-local-seam.sh` 会断言「上游文件没有被本地修改」，保证 `git merge` 永远干净。

### 焦点与输入框定位：分层兜底

输入法**无法强制**任何应用暴露输入框，AX 树质量取决于应用框架。因此按能力分层：

| 层 | 机制 | 覆盖 |
| --- | --- | --- |
| 1 | 系统级 `kAXFocusedUIElement` | 原生 AppKit 应用 |
| 2 | `AXEnhancedUserInterface` 开启后重试 | Electron / WebKit |
| 3 | IMK 原生路径（选区 + 回读校验） | Qt（如 QQ）、自定义编辑器 |
| 4 | 手动选中文字 | 万能兜底 |

第 3 层是这套实现里最关键的工程细节：**IMK 代理只在事件处理期间回答**。在识别完成后的异步任务里读 `selectedRange()` 会拿到 `0`、读 `attributedSubstring()` 会得到 `nil`。所以在事件处理内就把光标捕获进提交目标，跨度用算术定位，再用「光标是否仍停在跨度末尾」作为不可读客户端的证明。可读客户端仍走严格回读校验。

受保护字段（`isSecure`）**永不**进入任何回退路径。

### 延迟拆解（实测，6 字短句）

| 阶段 | 耗时 | 说明 |
| --- | --- | --- |
| 录音启动 | ~65ms | 已预热 |
| 松键 → ASR 最终文本 | 370~550ms | 服务端流式收尾 |
| 润色首字节 | 560~1500ms | **主要瓶颈，服务端响应** |
| 本地处理 + 上屏 | ~1ms | 本地几乎零开销 |

本地已无优化空间，剩余延迟在 ASR 与润色服务的网络往返。

---

## 支持的识别后端

内置预设，可完全自定义：Apple 系统听写、豆包流式/极速、阿里百炼、小米 MiMo、Fish Audio、Interfaze，以及任何 OpenAI 兼容端点。

润色与决策走 OpenAI 兼容协议，可对接方舟、Bailian、自定义网关等。

---

## 构建

要求 macOS 26+、Xcode、[xcodegen](https://github.com/yonaskolb/XcodeGen)。

```bash
bash scripts/local-preview-build64/build.sh <构建号> --install
```

产物在仓库上一级目录的 `dist/Build<构建号>/`，安装到 `~/Library/Input Methods/AIME Voice Preview.app`。构建号必须递增。

设成日常输入法前需在「系统设置 › 键盘 › 输入法」里添加，并授予**辅助功能**与**麦克风**权限。

测试：

```bash
swift test --package-path Packages/AIMEVoiceKit        # 93 项
python3 scripts/tests/test_voice_feature.py            # 宿主与 AX 改写场景
python3 scripts/tests/test_voice_routing.py <check>    # 路由与协议
bash scripts/check-local-seam.sh                       # 接缝断言
```

---

## 隐私

- 识别/润色所用服务由**你自己**在设置里配置，密钥存于本地 `~/Library/Application Support/AIME/`（权限 0600），不嵌入源码或安装包，不入库、不进日志
- 语音模块不持久化听写内容；最近听写溯源仅在内存中保留 5 分钟，用于支持紧接着的语音改写
- 本地输入法与 RIME 词库的处理方式遵循[上游隐私说明](docs/privacy.md)
- 自定义 STT 端点必须是 HTTPS，明文 `http://` 发往远程会被拒绝

---

## 许可

上游原创代码为 MIT；安装包包含 GPL-3.0 组件，请同时阅读[第三方声明](THIRD_PARTY_NOTICES.md)。本分支新增的语音模块代码同样以 MIT 发布。

语音改写模块参考 [Type4Me](https://github.com/joewongjc/type4me)（MIT）的设计，许可文本见 `licenses/type4me.LICENSE.txt`。
