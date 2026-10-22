# 本机更新 CLI 使用与接入合同

## 当前交付状态

更新日期：2026-10-14。当前为**安全 CLI 框架＋临时环境中的模拟安装、回退**。入口是 `scripts/local-update.py`，只使用 Python 标准库与 Git。完整本机进度见[当前进度](voice-module-implementation.md)。

**已提交的可构建定制基线尚未建立，6个生产 hooks 尚未绑定，Host 的持续空闲安装租约尚未接入。因此实机集成更新尚不可用。** 本机预览已通过独立的手工流程部署至 Build56；该部署不代表 CLI 已完成生产签名或安装接入。设置入口、App 编译和模拟测试也不改变上述限制。

缺少配置、受保护源码未纳入基线、hook 缺失或哈希变化、未取得空闲租约时拒绝安装。程序不猜测当前脏工作树、不自动提交源码、不默认用户处于空闲状态。

## 命令与 UI 接口

从项目目录执行；UI 应使用固定的解释器和脚本绝对路径，以参数数组调用，不拼接 shell：

```text
python3 scripts/local-update.py check --config /absolute/config.json --json
python3 scripts/local-update.py apply --config /absolute/config.json --upstream <40位完整SHA> --json
python3 scripts/local-update.py rollback --config /absolute/config.json --build <32位本机构建ID> --json
```

不传 `--config` 时只查找项目根目录的 `.local-update.json`；不存在即返回 `missing_config`。配置不放入语音模型设置，不含 API Key。

- `check`：在独立目录解析正式稳定发布，输出固定提交；不构建、不签名、不申请安装租约。
- `apply`：只能使用明确的完整 SHA，且必须仍对应配置发布列表中的正式稳定版。不会在构建期间重新选择 latest。
- `rollback`：选择已记录、保留且内容指纹一致的本机 App；不需要上游网络或发布列表，也不重新构建和签名。仍需验证产物、取得安装租约并确认启动。
- 退出码 `0` 成功，`2` 失败。正确调用下 `--json` stdout 只有一个最终 JSON 对象。参数语法错误由 argparse 输出到 stderr。
- 可选 `--events` 隐含 JSON 输出，stdout 改为 NDJSON：若干 `type:"progress"` 阶段事件，最后一个 `type:"result"` 完整结果。现有只读取最终 JSON 的 UI 不要启用此选项。

最终对象固定基本字段：

```json
{
  "schema_version": 1,
  "command": "check",
  "ok": true,
  "phase": "checked",
  "version": "v1.2.3",
  "upstream_commit": "完整40位SHA",
  "build": null,
  "rollback_build": null,
  "recovery": "unchanged",
  "error": null,
  "update_available": true,
  "installation": {
    "configured": false,
    "idle_checked": false,
    "error": {
      "category": "missing_config",
      "message": "Installation requires an explicit App, signing identity and six trusted hooks."
    }
  }
}
```

`check` 从 `current.json` 返回已有 `build` 和 `rollback_build`，新开的设置窗口无需记住上次命令结果。没有记录时为 null。回退执行时仍重新校验保留产物，ID 不构成无条件成功保证。

`installation.configured` 表示固定 hooks、安装配置及现有 App 的只读验证已通过；**不表示宿主空闲、已经取得租约或实机验收通过**。`idle_checked` 在 check 中始终为 false。安装基线内容失配或签名验证失败时，仍可返回成功的上游查询结果，同时设置 `configured:false` 和具体错误；apply 被阻断。源码基线缺失或受保护修改未提交属于无法正确整合的前置错误，整个命令失败。

其他按阶段出现的字段：`operation_dir`（仅 `apply`；`check` 用完即删临时检出，不返回该字段）、`baseline_commit`、`integration_commit`。错误对象包含 `category`、固定说明 `message`，可能增加 `conflicts`（相对源码路径）、`path` 或 `errno`。不输出 Git/hook 原始响应、密钥、录音或用户输入文本。

阶段：`config`、`resolve`、`checked`、`merge`、`verify-reference`、`verify-source`、`build`、`sign`、`verify-app`、`idle-gate`、`install`、`launch`、`recover`、`release`、`complete`。事件包含 `schema_version/command/phase/version/upstream_commit/build/recovery`；无进度百分比承诺，最终状态以 result 与退出码为准。

UI 可将 stdout 重定向到文件，避免 Settings 退出关闭管道。CLI 不负责为 UI 建立独立进程寿命；启动方不得把 Settings 关闭等同于强杀安装过程。

## 显式配置

以下为结构示例，不是可用的本机配置；不要用占位值尝试实机安装：

```json
{
  "schema_version": 1,
  "state_dir": "/absolute/local-integration-state",
  "baseline": {
    "repository": "/absolute/custom-source",
    "commit": "完整40位定制基线SHA",
    "upstream_commit": "完整40位共同上游基线SHA",
    "protected_paths": ["已归档的定制源码目录", "其他需保护的接入文件"]
  },
  "upstream": {
    "repository": "https://github.com/zoolapp/aime.git",
    "releases": "https://api.github.com/repos/zoolapp/aime/releases?per_page=100"
  },
  "installed_app": "/absolute/AIME Voice Preview.app",
  "signing_identity": "固定证书的40位十六进制指纹",
  "hooks_dir": "/absolute/reviewed-local-hooks",
  "hooks_sha256": {
    "verify-source": "对应脚本SHA256",
    "build": "对应脚本SHA256",
    "sign": "对应脚本SHA256",
    "verify-app": "对应脚本SHA256",
    "idle-gate": "对应脚本SHA256",
    "launch": "对应脚本SHA256"
  }
}
```

源码、状态及安装目录不得重叠。`protected_paths` 必须明确列全需要保护的代码和接入文件，必须已纳入指定提交；其工作树改动或未跟踪文件会阻断整合。其他未提交工作不复制、不覆盖。首次基线应先完成清单、保护范围分类与可构建确认；CLI 不自动完成或假定这些工作。

上游可以是绝对路径的本机镜像；`releases` 可以是绝对路径 JSON 文件，内容与 GitHub releases 数组格式一致。仅接受 `draft:false`、`prerelease:false` 且 tag 为 `v?主.次.补丁` 的记录，按数值版本排序。GitHub 模式只读取给定页面的公开发布信息，不使用登录凭据、不支持私有仓库；历史分页不自动扩展。正式 tag 解析为实际提交并验证上游祖先关系，移动 tag 不会让 apply 偷换用户指定 SHA。

所有 fetch、merge 在独立 operation/source 仓库中进行，禁用 Git hooks 和凭据 helper，不修改用户源码仓库。后续整合基于上次已安装记录保存的集成提交，保留 Git 历史。源目录与状态历史不可在使用期间随意删除。

## 内置实现与生产 hooks 的区别

内置：配置与基线约束、稳定版解析、独立 Git 合并、冲突停止、每个状态目录的互斥锁、三个 bundle 和输入源 ID 校验、产物内容指纹、安装日志、同文件系统原子目录交换、保留旧包、启动失败自动回退、离线显式回退。

**不内置生产 hooks。下面6个均需另行实现、审核并登记哈希；测试里的模拟脚本不能用于生产。** 既有 `build-app.sh` 或 `sign-voice-preview.py` 不会被 CLI 自动发现或调用。

| 固定文件名 | 生产职责 | 成功 JSON |
| --- | --- | --- |
| `verify-source.py` | 对已整合源码运行确认过的4组行为检查；不使用真实麦克风 | `{"ok":true,"checks":["host","runtime","settings","vocabulary"]}` |
| `build.py` | 从 `source_dir` 构建完整候选 App 至 `staged_app`；嵌入 Settings、XPC、依赖、资源及许可证；不复用旧 App 整包覆盖新源码 | `{"ok":true}` |
| `sign.py` | 只给暂存 App 签名，使用明确证书指纹，保留三个指定要求及 entitlements；不得自动查找/创建证书、迁移身份或安装 | `{"ok":true}` |
| `verify-app.py` | 只读验证签名与固定身份、指定要求一致、entitlements、许可证及数据兼容性 | `{"ok":true,"identity_verified":true,"entitlements_verified":true,"licenses_verified":true,"data_compatible":true}` |
| `idle-gate.py` | 持续空闲租约、禁止新任务、安装/回退前静止、租约释放 | 见下节 |
| `launch.py` | 在持有租约期间启动指定安装 App，并确认基本运行就绪；不能仅凭 open 退出码宣告成功 | `{"ok":true,"ready":true}` |

hook 由固定解释器以 `python -I /固定目录/固定名称.py` 调用；cwd 为 hook 目录。配置只指定目录与哈希，不能设置 shell、任意命令或 argv。每次执行前核验文件哈希。它是显式信任的本机执行扩展，不是安全沙箱；其实现必须同步完成工作，不得悄悄留后台签名/安装任务。

stdin 是单个 JSON 对象，stdout 必须是单个 JSON 对象，无日志前缀；非零退出、超时、空响应、错误 JSON 或缺少明确成功字段都会失败。build 超时1800秒，其他 hooks 180秒。CLI 隐藏原始 stdout/stderr；生产 hook 自行保留日志时也不得记录凭据。

通用请求字段：`schema_version:1`、`operation_id`、`source_dir`、`staged_app`、`installed_app`、`signing_identity`、`upstream_commit`、`version`。

- `verify-app` 收到 `purpose:"reference"` 时，`staged_app == installed_app`，只能只读确认已有签名基线，不得修补或重签。check/apply 都会使用此模式。
- 其他 verify-app 调用验证暂存产物及其与 installed_app 的兼容性。复制到安装目录同一文件系统后会再次验证。
- `staged_app` 是 CLI 分配的路径，不得由 hook 自行替换成在用路径。最初位于集成源码的 `build/LocalIntegration/` 中；同盘安装副本位于安装目录旁的 `.aime-local-*` 子目录。
- `launch` 使用 `installed_app`，不使用交换后已保存旧包的 `staged_app`；`action` 为 `start` 或 `restore`。
- 本机数据位置、语音设置、学习词库和 API Key 不由 CLI 迁移或覆盖。数据不可逆迁移时，验证 hook 必须拒绝更新，不能虚假确认回退兼容。

内置固定身份为宿主 `app.zool.inputmethod.aime.voicepreview`、Settings `app.zool.aime.voicepreview.settings`、XPC `app.zool.aime.voicepreview.service`，输入模式为 `app.zool.inputmethod.aime.voicepreview.hans`。三个 bundle 必须存在可用的内部可执行文件并使用同一个 CFBundleVersion。签名及完整数据路径检查仍由生产 verifier 落实，不能把文件结构检查当成签名验证。

## Host 安装租约合同

本轮无真实安装 IPC。`VoiceFeature.isIdle` 只是输入，不足以单独满足合同。实际 adapter 必须同时保护录音、识别、润色、改写、待上屏结果、组合输入、设置未保存状态，以及安装时相关进程的停止/重启。

门禁与 launch 请求增加 `runner_pid`；后续门禁/launch 调用携带 `lease`。门禁必须跨脚本进程持续持有状态；租约所有者死亡后的处理需由 Host/协调方实现，不能靠脚本退出即自动视为空闲。

| action | 必须完成 | 返回 |
| --- | --- | --- |
| `acquire` | 原子确认可更新，阻止新任务并保持租约，安全静止相关进程 | `{"ok":true,"idle":true,"held":true,"lease":"不可混用的令牌"}` |
| `validate` | 临近交换时确认仍持有相同租约 | `{"ok":true,"held":true}` |
| `quiesce` | 新包启动失败后，确认相关进程再次静止，仍阻止输入 | `{"ok":true,"idle":true,"held":true}` |
| `release` | 明确释放租约、允许正常使用 | `{"ok":true}` |

忙碌返回 `{"ok":false,"busy":true}`；未知状态拒绝，不补造成功字段。单次 isIdle 快照或脚本 exit 0 不视为持有租约。取得租约后，CLI 再核对 App 指纹才原子交换；不使用先删旧包再复制的安装方法。

## 恢复、保留与限制

`recovery` 的含义：

- `unchanged`：安装目录未交换。
- `previous_available`：新包安装并就绪，旧包保留，可用 `rollback_build` 请求回退。
- `restored`：新包未确认就绪，已恢复旧包并确认其基本启动。
- `restored_not_ready`：旧包文件已恢复，但启动未确认。
- `manual_required`：中断日志存在或恢复未完成，需要检查保留副本与状态；拒绝后续自动操作。
- `installed_gate_held`：安装完成但租约释放失败，命令返回失败；不能当作完整成功。

状态目录保存 `current.json`、`builds/<id>.json`、`pending.json`（事务未完成时）及独立源码目录。安装目录旁保留旧 App。正常显式回退会再保留当前版本，因此可以选择其他已验证记录。CLI 不回退用户词库或配置。

进程强杀、断电或人工改动不保证自动恢复：发现 pending 日志后停止，不猜测交换进行到哪一步，不自动删除日志。不要把“已有回退副本”等同于任意中断都可无人干预恢复。没有自动清理历史、发布更新包、后台定时更新、AI 自动解冲突或 TCC 重置。

## 测试与 TDD 证据

```text
python3 scripts/tests/test_local_update.py
```

25项现有 CLI 测试使用临时 Git 仓库、明确发布列表、模拟 Python hooks 和临时三 bundle App。正常/失败安装使用临时目录中的真实原子交换；没有真实签名、麦克风或在用 App 替换。UI、实际构建与生产 hooks 的接受结果不由该测试证明。

实现采用逐片红绿循环，工具输出保留了以下失败后通过的证据：

| 片段 | 首次观察的失败 | 完成行为 |
| --- | --- | --- |
| 缺失配置 | 脚本尚不存在，stdout 无 JSON | 明确 missing_config |
| 稳定版检查 | 返回 invalid_config | 解析稳定 tag 并固定 SHA |
| 冲突/固定提交 | apply 被误当 check 成功 | 冲突停止、拒绝 latest/预览提交 |
| 构建失败 | 停在 missing_config | build_failed、旧包保留 |
| 空闲门禁 | 安装流程尚未实现 | busy 阻断交换 |
| 安装 | 门禁后仍缺少安装实现 | 临时 App 原子交换并记录旧包 |
| 启动失败 | recovery 为 previous_available | 恢复旧包并确认启动 |
| 显式回退 | 错误依赖已删除发布列表 | 离线回退 |
| 连续更新 | 缺少 update_available | 沿用上次集成提交、拒绝重复更新 |
| 输入源身份 | 错误模式仍安装成功 | identity_mismatch |
| 租约释放失败 | ok 仍为 true | 明确失败及 installed_gate_held |
| JSON 进度 | 不识别 --events | 阶段事件和最终结果 |
| 安装配置状态 | 缺少 installation | 区分可查询与可安装前置条件 |
| 中断状态 | 错误返回 unchanged | manual_required |
| 新开 UI 回退 | build 为 null | 返回持久化 build/rollback_build |
| 未签名基线 | 错误宣告 configured:true | 查询继续、安装拒绝 |

另有现有行为回归覆盖 hook 缺失/篡改、签名失败、无租约的 exit 0、未提交定制、互斥锁、原子交换失败及移动 tag。本轮最终运行：`Ran 25 tests in 18.838s — OK`，退出码0；生产安装条件仍未满足。
