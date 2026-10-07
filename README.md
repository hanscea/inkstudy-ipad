# InkStudy | iPad 绘画研究工具

InkStudy 是用于色彩、线条和综合创作研究的原生 iPad 项目。它记录 Apple Pencil 笔迹、压力与操作过程，提供混色和力度练习，并将作品、原始记录和研究访次一起导出。最新提示演练入口在混色与力度任务中提供短句、动作示范和普通话朗读。

本仓库从 **2026-10-07 的当前源码快照**开始管理，只包含原生 App、核心模块、Node.js 服务端、测试、必要模型资源和协作文档。早期 Web Demo、历史安装包、研究计划书、设备备份、实验数据和密钥留在仓库之外。

## 先选择要运行的入口

两个 App 来自同一份当前源码，使用不同的 Bundle ID 和独立的数据沙盒。

| 目标 | Xcode Scheme | 当前版本 | 适用场景 |
| --- | --- | --- | --- |
| 绘画提示测试 | `InkStudyHints` | 0917H1 / 0.5.0 / build 1 | 最新提示交互演练：混色、力度、固定提示与自适应提示 |
| 绘画记录 | `InkStudy` | 0911V4 / 0.4.4 / build 9 | 完整色彩、线条、综合创作、研究访次和作品导出 |

**初次体验最新交互，选择 `InkStudyHints`；查看完整研究流程，选择 `InkStudy`。** 仓库不提供可直接安装的签名包，合作者需要用自己的 Xcode 和开发团队构建。

## 功能

- **绘画与记录：** 原生 Pencil 输入、压力与倾角采样、估计属性修正、撤销重做、本地 SQLite 持久化和画纸恢复。
- **混色：** 六种指定 sRGB 色卡，目标间色自动匹配两种原色；每次蘸色有有限颜料量，后续涂抹和搅拌改变局部分布，余量耗尽后只搅拌。
- **线条：** 轻、中、较重及变化力度练习、路径与情境线条。训练和测量采用不同的反馈规则。
- **多模态提示：** 本地短句、动作动画、画纸定位圈和系统普通话语音。B 组使用固定序列，C 组根据操作摘要选取审核过的动作策略。
- **研究流程：** 基线、训练、后测、迁移及延迟测；保留首次技术有效试次、暂停恢复、操作协助与提示记录。
- **导出：** PNG、JSON、CSV、SHA-256 清单和访次 ZIP，可用随附脚本核验。
- **可选云端服务：** DeepSeek 提示策略选择和万相草图生成使用独立 Node.js 服务；API Key 不进入 iPad 安装包。

当前云端提示入口用于成人或虚构示例演练。正式儿童采集入口尚未开放，提示阈值及压力目标仍需现场验证。软件测试结果见[本次交付验证](docs/collaboration/VALIDATION.md)。

## 环境

| 部分 | 要求 |
| --- | --- |
| iPad App | macOS、完整 Xcode、Swift 6 工具链、iOS/iPadOS SDK；最低 iPadOS 17 |
| 真机输入 | 兼容 iPad 的支持压感的 Apple Pencil；手指和模拟器不能验证真实压力 |
| Core 单元测试 | macOS 14 或更新版本、Swift 6 工具链 |
| 服务端 | Node.js 22 或更新版本；没有第三方 npm 运行依赖 |
| 工程生成 | XcodeGen，可选；仓库已包含生成后的 `.xcodeproj` |

代码整理时使用的具体工具版本及检查结果记录在[验证文档](docs/collaboration/VALIDATION.md)。真机签名、设备信任和开发者模式由每位合作者在自己的设备上配置。

## 获取项目

私有仓库需要先接受维护者的协作者邀请。登录有访问权限的 GitHub 账号后，可以使用 GitHub Desktop、GitHub CLI 或已配置的 Git 凭据克隆：

```sh
git clone https://github.com/hanscea/inkstudy-ipad.git
cd inkstudy-ipad
```

只阅读代码也可以使用 GitHub 的 **Code → Download ZIP**。需要提交修改时请使用 Git 克隆。

## 快速运行 App

1. 用 Xcode 打开 `native/InkStudy/InkStudy.xcodeproj`。
2. 选择 `InkStudyHints`，再选择一个 iPad 模拟器。
3. 点击 Run。首页选择 B 或 C、混色或力度；可以载入虚构示例笔迹。
4. 手动画完一笔后请求提示。B 组无需服务器；C 组云端不可用时会显示并记录本地回退提示。
5. 要查看完整活动与访次，将 Scheme 改为 `InkStudy`。

真机运行时，在对应 target 的 **Signing & Capabilities** 中选择自己的 Team；必要时将 Bundle Identifier 改为自己团队可用的标识。保持两个 App 的标识不同。测试 target 也需使用相应签名设置。重新生成工程会覆盖 Xcode 中的临时配置，签名修改请留在本地，不提交个人团队配置。

如果终端提示只有 Command Line Tools，请为当前终端指定完整 Xcode，不必修改全局工具链：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

需要从配置重新生成工程时：

```sh
cd native/InkStudy
xcodegen generate
```

不依赖设备签名的模拟器构建检查：

```sh
# 在仓库根目录执行
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project native/InkStudy/InkStudy.xcodeproj \
  -scheme InkStudyHints -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/InkStudyBuild CODE_SIGNING_ALLOWED=NO build
```

该命令只验证编译，不执行需要钥匙串的配对测试。运行 App 集成测试的命令见[验证文档](docs/collaboration/VALIDATION.md)。

## 可选：连接 DeepSeek 提示服务

服务端接收任务、目标、笔画数和白名单数值摘要。模型返回一个允许的策略编号，文字、动画与语音由 App 本地提供。接口默认使用 `deepseek-flash`；请求和返回的模型标识、提示库版本及回退原因写入记录。

将自己的密钥保存在仓库外的 UTF-8 文件中，格式如下。下方只是格式示意，`YOUR_DEEPSEEK_API_KEY` 需要替换成自己的有效密钥：

```text
DeepSeek API KEY: YOUR_DEEPSEEK_API_KEY
```

在仓库根目录执行，路径替换为自己机器上的绝对路径：

```sh
node native/InkStudy/Bridge/hints-cli.mjs configure \
  --key-file /absolute/private/deepseek-credentials.md --daily-limit 30
node native/InkStudy/Bridge/hints-cli.mjs serve --host 0.0.0.0 --port 8788
```

保持服务运行，在另一个终端生成一次性配对码：

```sh
node native/InkStudy/Bridge/hints-cli.mjs pair
```

Mac 和 iPad 应位于同一可信局域网。在“绘画提示测试 → 连接设置”中输入服务启动时打印的局域网地址和配对码，再开启成人/虚构示例演练同意。模拟器可使用 `http://127.0.0.1:8788`；真机不能用这个地址连接 Mac。

默认运行目录是 `~/Library/Application Support/InkStudyHintBridge`。若使用 `--runtime` 自定义目录，`configure`、`serve` 和 `pair` 必须传入同一个目录。配置只记录密钥文件路径，不复制密钥。

服务使用八秒上游超时、两路并发和持久化每日请求上限。配对码十分钟有效且只能使用一次。API 调用可能计费；常规单元测试使用模拟提供商，不调用付费接口。更完整的限制和运维命令见[提示服务说明](native/InkStudy/Bridge/HINTS_README.md)。

万相是“绘画记录”中的独立可选体验，默认使用端口 8787 和不同的运行目录。它会上传确认后的 PNG 与描述，不是提示服务的一部分。配置见[万相服务说明](native/InkStudy/Bridge/README.md)。

## 测试

在仓库根目录执行：

```sh
# Core：协议、记录、混色、提示策略等
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path native/InkStudy/Core

# 两种 Bridge：模拟上游接口，不使用真实 API Key
node --test native/InkStudy/Bridge/bridge.test.mjs \
  native/InkStudy/Bridge/hints.test.mjs
```

也可以在 `native/InkStudy/Bridge` 中执行 `npm test`。测试无需 `npm install`。

真实 API 冒烟脚本和 `INKSTUDY_LIVE_HINT_TEST=1` 会启用云端调用，默认不运行。Core 和模拟器测试不能代替 Pencil 压感、实际音量、儿童理解度或教学效果验证。

## 数据与隐私

作品和原始事件保存在 App 沙盒中，导出时生成副本。不要通过卸载 App 或删除数据库来处理保存失败，也不要仅复制 SQLite 主文件代替完整导出。

| 导出内容 | 用途 |
| --- | --- |
| `artwork.png` | 当前作品，不含提示覆盖层 |
| `raw.json` / `samples.csv` | 原始事件、最终修正后的采样及笔画状态 |
| `manifest.json` | 文件 SHA-256 与完整性信息 |
| `study.json` / `trials.csv` / `responses.csv` | 访次事件、尝试与回答 |
| `hints.csv` / `hint-delivery.csv` | 最新提示演练中的策略、来源、显示与语音生命周期 |

导出结构与版本规则见[原生工程说明](native/InkStudy/README.md)和[研究实施说明](native/InkStudy/RESEARCH_GUIDE.md)。独立核验命令：

```sh
node native/InkStudy/scripts/validate-export.mjs /absolute/export-directory
node native/InkStudy/scripts/validate-research.mjs /absolute/unzipped-study
```

API Key、配对状态、令牌、儿童作品、参与者代号映射、原始实验导出、签名文件及运行日志不得提交到 GitHub，包括私有仓库。提示服务只上传数值摘要；万相上传图像，必须分别管理授权和数据方案。HTTP 局域网模式仅供可信环境中的成人或虚构材料测试。

## 目录

```text
native/InkStudy/
  App/                 SwiftUI 界面、UIKit 输入、渲染、持久化与导出
  Core/                Swift Package：数据结构、研究协议、混色与提示策略
  AppTests/            App 集成测试
  HintPreview/         独立提示 App 配置
  HintUITests/         提示界面测试；真实 API 用例默认跳过
  Bridge/              DeepSeek 提示与万相图像服务
  ThirdParty/          Spectral.js 来源及许可证
  scripts/             模型资源生成、打包检查和导出核验
  InkStudy.xcodeproj/   已生成的 Xcode 工程与共享 Schemes
  project.yml          XcodeGen 工程配置源
docs/collaboration/    架构与本次交付验证
CONTRIBUTING.md        协作、测试及提交要求
```

## 协作与常见问题

- **打不开仓库或出现 404：** 确认当前 GitHub 账号已接受该私有仓库邀请。
- **签名失败：** 使用自己的 Apple Team 和可用 Bundle ID，不需要维护者的签名证书。
- **力度不变化：** 模拟器、手指及不支持压感的输入不能验证压力；先检查 Pencil 与设备兼容性。
- **C 组显示本地回退：** 检查成人演练开关、配对、服务进程、局域网授权及服务调用上限。回退来源会进入日志。
- **命令找不到模拟器或工具链：** 检查完整 Xcode 路径与已安装的 iOS Simulator runtime。
- **想贡献修改：** 按[协作说明](CONTRIBUTING.md)新建分支和 Pull Request；任务入口与源码对应关系见[架构说明](docs/collaboration/ARCHITECTURE.md)。

维护者通过 GitHub 仓库的 Collaborators 设置邀请合作者。代码访问与研究数据访问分别授权。本仓库暂未为原创代码设置开源许可证；第三方 Spectral.js 的 MIT 许可证及版权声明随源码保留。
