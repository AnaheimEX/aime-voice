# 本机定制

这个仓库是 [zoolapp/aime](https://github.com/zoolapp/aime) 加上只在本机使用的语音输入和词库定制。上游文件除少量挂钩外保持原样，定制都在本地文件里；结构与同步方法见[与上游同步](docs/upstream-merge.md)。

| 主题 | 文档 |
| --- | --- |
| 同步上游、挂钩白名单、冲突处理 | [与上游同步](docs/upstream-merge.md) |
| 构建、签名、安装本机预览 | [scripts/local-preview-build64/README.md](scripts/local-preview-build64/README.md) |
| 当前进度与剩余工作 | [当前进度](docs/voice-module-implementation.md) · [模块契约](docs/voice-module-design.md) · [本机更新合同](docs/local-update-usage.md) · [本机架构决定](docs/adr/) |
| 文字词库与语音词典 | [用途、机制与隔离边界](docs/dictionary-isolation.md) |
| 隐私 | [本机语音功能隐私说明](docs/voice-privacy.md) |
| 语音接入记录 | [Fish 原生 STT](docs/fish-native-asr.md) · [Laya 本地决策与评估](docs/laya-local-decision.md) · [FluidVoice 接入评估](docs/fluidvoice-integration-assessment-2026-10-15.md) |
| 许可 | [本地第三方声明](licenses/LOCAL_THIRD_PARTY_NOTICES.md) |

常用命令：

```bash
scripts/sync-upstream.sh --dry-run                     # 预报上游合并冲突
scripts/sync-upstream.sh                               # 合并上游并检查接缝
scripts/check-local-seam.sh --build                    # 接缝检查 + 编译 + 本地测试
scripts/local-preview-build64/build.sh <构建号> --install  # 构建、签名并安装预览
```
