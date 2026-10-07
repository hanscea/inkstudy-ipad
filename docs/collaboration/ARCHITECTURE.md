# 架构与代码导航

## 两个 App 入口

`App/InkStudyApp.swift` 通过编译条件 `HINTS_PREVIEW` 选择首页。

| Scheme | App target | 首页 | Bundle ID |
| --- | --- | --- | --- |
| `InkStudy` | `InkStudy` | `ResearchHome` | `cn.xinsun.inkstudy.prototype` |
| `InkStudyHints` | `InkStudyHintPreview` | `HintPreviewHome` | `cn.xinsun.inkstudy.hintpreview` |

两者使用同一套 App 和 Core 源码，但安装与数据沙盒独立。仓库中没有两个拷贝的历史源码目录。Bundle ID 在自己的开发团队下不可用时，应在本地修改并重新签名。

## 模块关系

```text
SwiftUI 任务界面 / ResearchController
           |
           +--> NativeCanvas / UIKit Pencil 输入
           |          |
           |          +--> Core 数据模型、混色与事件持久化
           |          +--> 原生绘制 / 作品预览 / 导出
           |
           +--> 本地提示候选规则 --> 文字、动画、系统语音
           |          |
           |          +--> 可选 HintClient --> Node 提示服务 --> DeepSeek
           |
           +--> 独立 GenerationClient --> Node 图像服务 --> 万相
```

云端提示只返回策略编号，不修改画纸。万相生成图与儿童原作分别保存。

## 修改位置

以下路径均相对于 `native/InkStudy/`。

| 关注点 | 主要文件 |
| --- | --- |
| 首页与研究活动 | `App/ResearchHome.swift`、`ResearchActivities.swift`、`ResearchRunner.swift` |
| 最新提示演练入口 | `App/HintPreviewHome.swift` |
| Pencil 采样与画布 | `App/NativeCanvas.swift`、`InkRenderer.swift` |
| 混色显示与交互 | `App/PigmentMixingView.swift`、`PigmentRenderer.swift`、`PigmentDisplayController.swift` |
| 颜料量、搅拌和颜色规则 | `Core/Sources/InkStudyCore/PaletteMixing.swift`、`StandardPalette.swift`、`PigmentSurface.swift` |
| 研究访次与任务编排 | `Core/Sources/InkStudyCore/ResearchProtocol.swift`、`ResearchTasks.swift` |
| 保存与恢复 | `App/StudioModel.swift`、`ResearchController.swift`；Core 的 `JournalStore.swift`、`ResearchStore.swift` |
| 本地传统反馈 | `Core/Sources/InkStudyCore/ResearchFeedback.swift`、`Resources/state-model.json` |
| 新提示策略与白名单 | `Core/Sources/InkStudyCore/MultimodalFeedback.swift`、`Bridge/hints.mjs` |
| 新提示动画与语音 | `App/MultimodalHintView.swift`、`Narration.swift` |
| 提示网络客户端 | `App/HintClient.swift` |
| 万相客户端与界面 | `App/GenerationClient.swift`、`GenerationModel.swift`、`GenerationView.swift` |
| 作品与研究导出 | `App/ExportService.swift`、`ResearchExport.swift`；Core 的 `RawExport.swift` |

## 提示数据流

1. App 从当前画纸计算证据，保存本地画纸 ID、序号和定位信息。
2. Core 按任务与实际操作建立候选动作集合；首次尝试、训练阶段、组别、三次上限和十五秒间隔决定是否允许提示。
3. B 组从固定序列取动作。C 组在用户启用成人/虚构演练且服务可用时，将白名单数值摘要发给提示服务。
4. 服务校验设备令牌、请求 UUID、字段与候选集合，通过固定 DeepSeek 端点请求一个策略编号，并校验返回结果。
5. App 再次检查返回策略。调用失败或不可用时使用本地候选动作，明确记录回退原因。
6. 本地渲染文字与动画，用系统语音朗读，记录显示、开始、完成、中止或失败等生命周期。

`HintEvidence` 包含本地证据，`HintSummary` 是网络允许传输的子集。画纸坐标、作品图片、录音、身份信息和原始触控不在提示摘要中。

## 持久化与网络职责

App 保留 SQLite 原始事件与研究 JSON 记录。导出是经过保存后的副本，附带文件哈希。屏幕绘制与作品导出共用核心规则，提示覆盖层不进入作品。

DeepSeek 服务默认使用 `InkStudyHintBridge` 运行目录和 8788 端口；万相服务使用 `InkStudyBridge` 与 8787 端口。两个服务分别配对，不能互换配对码。服务端运行目录保存鉴权或任务状态，应放在仓库之外并按数据方案备份。

提示服务的 UUID 回执与图像服务的任务状态用于避免重复调用。清空运行目录会丢失这些记录；故障恢复应使用服务自带命令，不以删除目录代替恢复。

## 兼容性与资源

新混色画纸使用 `standard-palette-v4` 和 `standard-rgb-v1-20260911`。旧画纸的模型标识仍决定回放方式，因此 Spectral 查找表、旧模型实现与相关测试属于当前代码依赖，不能作为“旧版本文件”删除。

`project.yml` 是工程配置源，`.xcodeproj` 方便直接打开；二者应同步提交。真实设备签名信息留在合作者本机。Core 的模型、颜料表和许可证必须随 App 打包，可用 `scripts/verify-app-package.sh` 核验生成的 App。
