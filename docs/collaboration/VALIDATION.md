# 当前源码快照验证

交付日期：2026-10-07。验证范围为当前原生工程、核心模块与两种 Node.js Bridge，不使用真实儿童材料或付费模型调用。

## 本次检查

工具链：Xcode 27.0（27A266a）、Apple Swift 6.4、Node.js 24.15.0。

| 检查 | 本次结果 |
| --- | --- |
| Core 单元测试 | 57 项通过，0 失败 |
| DeepSeek 与万相 Bridge 模拟接口测试 | 24 项通过，0 失败；包含回环 HTTP 配对与鉴权 |
| `InkStudyHints` 模拟器构建 | 通过 |
| `InkStudy` 模拟器构建 | 通过 |
| 两个 App 内的模型、颜料表与许可证核验 | 通过，打包资源与源码资源逐字节一致 |
| 仅从 Git 暂存区导出的干净源码副本 | `InkStudyHints` 构建与打包资源检查通过 |
| 上传内容检查 | 仅当前源码与文档；本地实际凭据匹配、个人构建配置、禁止路径和相对文档链接检查通过 |

本次未重新执行真机或模拟器 App/UI 集成测试，也未调用真实 DeepSeek 或万相接口。Core 与 Bridge 的测试结果不替代这些检查。历史真机结果没有计入本表。

受限执行环境最初阻止了本机 HTTP 端口与 Swift 缓存访问；在允许这些本机测试资源后，完整测试重新通过。此项属于测试环境限制。

## 可复现命令

以下命令在仓库根目录执行。Xcode 安装位置不同时调整 `DEVELOPER_DIR`。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift test --package-path native/InkStudy/Core
node --test native/InkStudy/Bridge/bridge.test.mjs \
  native/InkStudy/Bridge/hints.test.mjs

xcodebuild -project native/InkStudy/InkStudy.xcodeproj \
  -scheme InkStudyHints -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/InkStudyBuild CODE_SIGNING_ALLOWED=NO build
xcodebuild -project native/InkStudy/InkStudy.xcodeproj \
  -scheme InkStudy -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/InkStudyBuild CODE_SIGNING_ALLOWED=NO build
```

App 集成测试需要一个已安装的 iPad Simulator。先列出设备，用实际 UDID 替换占位符；每次指定一个新的结果目录。模拟器钥匙串测试使用临时签名 `-`，不是 Apple 真机签名。

```sh
xcrun simctl list devices available
xcodebuild -project native/InkStudy/InkStudy.xcodeproj \
  -scheme InkStudyHints -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath /tmp/InkStudySignedTests \
  -resultBundlePath /tmp/InkStudyHints-tests.xcresult \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

未设置 `INKSTUDY_LIVE_HINT_TEST=1` 时，真实 DeepSeek UI 用例应跳过。该跳过不计为云端链路通过。

## 真机与现场检查

合作者使用自己的签名，在兼容 iPad 和支持压感的 Pencil 上检查轻重变化、掌触、撤销重做、保存恢复、横竖屏、语音音量与完整导出。自动化测试不能代替这些输入和现场检查。

正式研究开始前，需要冻结 commit、App 版本、任务协议、提示库、模型配置、题本与数据方案。工程提示阈值、合成模型和语音播放完成记录分别反映算法设置、软件行为和播放状态，不是已验证的学习效果。
