# 语音改写修复进度

计划见 [rewrite-fix-plan-2026-10-26.md](rewrite-fix-plan-2026-10-26.md)。

## 当前状态

阶段 0、1 完成。阶段 1 已装到 Build76，用户手动验证通过（Esc 取消后光标在句末，再打字不覆盖），检查点 1 通过。阶段 2 已实现，用户确认收紧为「仅纯删除和纯插入」，已装到 Build77。待用户在真实 App 里手动验证新措辞改写，并决定是否授权小规模真实模型评估。

## 阶段 0（2026-10-26）

**改了什么**
- `Package.swift`：新增 testTarget `AIMEVoiceRewriteTests`（依赖 AIMEVoice、AIMEVoiceHost，沿用 strictSwift，用 XCTest）。
- 新增 `Tests/AIMEVoiceRewriteTests/`：`FakeRewriteAccessibility.swift`（含 `FakeRewriteAccessibility` 和实现 `IMKTextInput` 的 `FakeTextInput`）、`FakeRewriteAccessibilityTests.swift`（5 个）、`VoiceRewriteCharacterizationTests.swift`（11 个）。
- `VoiceRecentDictation`：新增只读属性 `originAgeMilliseconds`。
- `VoiceRewriteSelection.swift`：新增 `VoiceRewriteTargetReason` 枚举和并行纯函数 `targetFailureReason`；`preparationFailureMessage` 未改。
- `VoiceFeature.startVoice` 改写分支：新增日志 `stage=rewriteTarget outcome=hit|miss reason=<枚举> resolveMs prepareMs originAgeMs`，只有枚举和毫秒。原有守卫顺序、提示文案、`beginVoice` 调用不变。

**测试与验证**
- 我自己重跑：`swift test` 新目标 16 个测试 0 失败；`swift build --target AIMEVoiceHost` 通过；`scripts/check-local-seam.sh` 输出 `local seam: ok`。
- 对基线备份做了 diff，改动全是新增，没有改旧逻辑。
- `swift test` 在本机可行，不需要备用办法。

**还没测**
- 日志在真实输入法里的实际输出和耗时，需要装机后用 `log stream` 过滤 `stage=rewriteTarget` 确认。
- `VoiceFeature.startVoice` 的日志路径没有自动化测试（依赖 IMK 会话）。
- `cancelled` 在两处使用，其中「找不到当前输入客户端」也记为 `cancelled`，略不精确，可在后续阶段顺手拆开。
- 过期记录被 `latest()` 清空后，下一次 `originAgeMs` 读到 -1，过期原因落入 `noOrigin`，没有单独的过期项。

**阶段 0 发现，影响后续阶段**
1. 更正我审查时的一个说法：模型返回 `intent=unsupported` 时的提示是「未识别到支持的文本改写指令」，只有 `ambiguous=true` 才是「改写指令不明确，请说明要修改的内容」。我之前的模拟响应同时设了 ambiguous，所以混在一起了。
2. 新缺陷：前置序数说法如「把第二个好的改成行」当前无法工作。分析器把「第二个好的」整体当成旧值，定位失败，报「未找到要修改的内容」。写成「把好的改成行，第二个」或「最后一个」才行。这条不在原计划里，优先级待用户定。
3. 显式替换有授权时，校验器会自己对授权区间重新应用替换，模型改了别处会被纠正成正确结果，而不是拒绝。
4. 为 `VoiceRewriteSelection` 写 `IMKTextInput` 桩可行，不需要改生产代码可见性（需实现 `supportsProperty`）。阶段 1 的恢复光标逻辑可以直接用这套 Fake 测试。

## 阶段 1（2026-10-26）：选区残留修复

**改了什么**
- `VoiceRewriteSelection.restoreCaretIfNeeded(client:)`：仅对自建选区（`isRecentDictation`）；要求同一输入框、内容逐字相同、当前选区正是我们选中的区间；满足才用一次 AX select 把光标折叠到原选区末尾。同步、不重试、不轮询、不写任何文字；幂等；已成功插入的不恢复。结果枚举 `VoiceRewriteRestoreOutcome` 供日志。
- `VoiceFeature`：会话加 `committed` 标记（`insert` 返回成功后置位）；`cancelVoice` 在未提交时恢复；新增 `preparingSelection` 处理准备阶段（`voice` 还是 nil 时）的失败和取消；新增日志 `stage=rewriteRestore outcome=restored|skipped reason=<枚举>`。
- 没有新增 await，原有提示文案、守卫顺序、成功路径不变。

**验证**
- 我自己重跑：`swift test` 40 个测试 0 失败（改写 27，其中阶段 1 新增 11；设置 13）；`swift build --target AIMEVoiceHost` 通过；`scripts/check-local-seam.sh` 输出 `local seam: ok`。
- 对基线备份做了 diff，只改了计划内的位置，`Package.swift`、`Type4MeRevise*.swift`、`VoiceRewriteEngine.swift` 未动。

**有自动化测试的**：恢复本身及各种跳过条件、只移动光标不写文字、幂等、select 失败不抛不重试、「是否恢复」的判断表。

**只靠代码审查、没有自动化测试的**：Esc 取消、识别为空、模型出错、校验拒绝、无修改、超时、服务断开、准备阶段失败或取消、`deactivate` 和 `shutdown`。这些都收敛到 `cancelVoice` 或 `reject → cancelVoice`，需要在真实 App 里手动验证。

**已知边界**
- `restored` 只表示 select 调用成功，没有回读确认光标真的折叠了（计划要求一次尝试不轮询）。
- `fieldChanged` 日志合并了未授权、换输入框、bundle 不符、输入框不可用几种情况，分不开。
- `insert` 写入后回读未确认就返回拒绝时，输入框内容已变，恢复会因内容变化而跳过，不会有副作用。
- 改写结果与原文相同时 `insert` 按成功处理，选区保持选中（原有行为，没碰）。

## 阶段 2（2026-10-26）：新措辞式改写

**改了什么**
- `Type4MeRevisePrompt.swift`：EDITING CONTRACT 加 RESTATEMENT 规则（指令是目标文字或其一部分的修改后说法时，按 replace、literal 处理，只换该片段，不带说话时的句末标点和语气词），并加「与目标无关仍按 unsupported」。
- 新增 `VoiceRewriteRestatement.swift`（纯函数）：Sellers 半全局编辑距离找最佳窗口；准入过滤、唯一性、受保护事实、重复片段检查后，经现有 `ReviseOutputValidator` 校验；校验被拒或无变化一律返回 nil 交给模型，不抛错。
- `VoiceRewriteEngine`：新增 `LocalResolution`（`.explicit` / `.restatement`）和 `localResolution(for:)`，先显式替换，后新措辞；`localCandidate` 签名保留。
- `VoiceProcessor.rewrite`：新措辞命中 route 为 `rewrite_local_restate`，显式仍为 `rewrite_local`。
- 新增 `docs/rewrite-restatement-eval-cases.json`（10 条评估用例，未调用任何真实模型）。

**阈值（全在 `VoiceRewriteRestatement.Limits`）**
指令长度 4–80；目标长度 ≤ 2000；编辑距离 d 满足 1 ≤ d ≤ max(1, m/4)；窗口必须唯一（无不重叠且距离不大于 d 的另一窗口）；否定字符（不没别无非未勿否）计数不同则放弃；数字类字符多重集不同则放弃；窗口原文在目标里出现多于一次则放弃；窗口两端不能是标点或空白。

**测试与验证**
- 我自己重跑：`swift test` 44 个 0 失败（新措辞 17 个，改写共 31，设置 13）；`swift build --target AIMEVoiceHost` 和 `--build-tests` 通过；`check-local-seam.sh` 输出 `local seam: ok`；eval JSON 合法。
- 有意更新了阶段 0 的两条特征测试：本地快路径对「把海报发我」「把海报发我。」及长句里的小段由返回 nil 改为命中。其余阶段 0、1 测试一条未动。
- 性能：目标 2000 字、指令 80 字，debug 构建下含校验器约 0.12–0.18 秒；release 没测。

**实现中发现并处理的问题**
- 计划里的平局规则（更短、更靠前）在重叠窗口会产生错误结果：目标「我们去公园玩耍」配「我们去公园玩乐」会输出「我们去公园玩乐耍」，且现有校验器放行。处理：排序先按编辑次数、再按精确匹配字符数；仍有多个同等最优窗口时一律返回 nil。比计划更保守，需在检查点确认。
- 校验器对否定词几乎没有拦截，中文数字也未必被事实提取器识别，所以快路径里自己加了否定词和数字的对比，没动校验器。

**误改风险（子代理自评，我认同）**
1. 差一个字的真替换会直接命中，如「我喜欢红色」配「我喜欢蓝色」；没有语义判断，若用户是在口述别的话而不是改写就会误改。
2. 程度词和情态词（很/非常、能/可以/必须）不在保护集合里，会被放行。
3. 长句里一个短近似窗口（如「周五开会，周六开会」配「周五评会」）只靠唯一性和 d 上限挡。

**没测的**：真实模型对新措辞规则的遵循；真实 App；release 性能；`scripts/tests/VoiceRewriteCheck.swift`（需另外的编译方式）；日志里 `rewrite_local_restate` 是否被现有统计识别。

**检查点 2 决定（用户）**：本地快路径只允许纯删除和纯插入，任何字符替换都交给模型。
- 实现：在选出窗口后检查「指令是窗口的子序列，或窗口是指令的子序列」，否则返回 nil（`isPureDeletionOrInsertion`）。
- 顺带修了一个边界：窗口若会吞掉目标里的标点，不再算作「同等最优的对手」。否则在句末标点前做纯插入（如「…玩，然后…」配「…玩耍」）会被误判为歧义而放弃。
- 测试：新增 `testSubstitutionsAreLeftToTheModel`、`testPureDeletionOrInsertionGate`，改写了阈值边界测试为删除和插入用例，并把原来的替换命中用例移到「返回 nil」。我自己重跑：`swift test` 46 个 0 失败；`swift build --target AIMEVoiceHost` 和 `--build-tests` 通过；`check-local-seam.sh` 输出 `local seam: ok`。
- 评估用例清单：「我们明天去商场玩」预期改为走模型，新增一条纯删除用例。
- 已构建安装 Build77，输入源已恢复。已删除旧的 Build74、75、76 目录；保留 `dist/Build77/work/previous-build76.zip` 作为回退包。

## 下一步

用户在真实 App 里手动验证：听写「把海报发给我」，开改写说「把海报发我」，确认结果为「把海报发我」；再试一句只改一个字的替换，确认走模型（日志 `route=rewrite`，而不是 `rewrite_local_restate`）。通过后进入阶段 3。真实模型评估需要用户授权后另做。
