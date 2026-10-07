# 绘画记录：原生 iPad App

SwiftUI + UIKit 原生工程，最低 iPadOS 17。当前代码提供完整研究入口 **0911V4（0.4.4，build 9，Scheme `InkStudy`）** 和独立提示演练入口 **0917H1（0.5.0，build 1，Scheme `InkStudyHints`）**。两者共享源码，分别保存数据。首次获取与运行见[项目首页](../../README.md)。

混色目标自动配对：橙色用红黄，绿色用黄蓝，紫色用红蓝。新色卡和画纸使用指定的六组 RGB 值，有限颜料与逐步搅拌保留；旧画纸按原颜色和模型回放。最新提示演练增加动作示范、定位圈、普通话朗读和可选 DeepSeek 策略选择。

当前构建与测试结果见[源码快照验证](../../docs/collaboration/VALIDATION.md)。本仓库不包含历史安装包和设备测试备份。

研究流程、测量规则和两种提示入口见[研究实施说明](RESEARCH_GUIDE.md)。提示服务见[DeepSeek Bridge](Bridge/HINTS_README.md)，独立图像服务见[万相 Bridge](Bridge/README.md)。

## 使用

- 六色参数为大红 `#FF0000`、柠檬黄 `#FFFF00`、湖蓝 `#0000FF`、橙 `#FFA500`、绿 `#00FF00`、紫 `#800080`。研究线条任务沿用单独的墨色。
- 笔刷范围为 4–96 个画纸单位，快捷档位为 6、24、52、96。画纸固定为 1200 × 850 个逻辑单位，缩放与横竖屏切换不改变作品比例。
- 支持压力的 Apple Pencil 通过原生 `UITouch` 采样驱动粗细变化。画布默认不接收手指，可打开“手指预览”试画。
- 所有活动不限时。自由画纸和开放绘画不设笔画数量上限；受控线条任务逐条保存，测量采用每条试次的首次有效记录。撤销、重做和再次落笔都记录事件；被撤销的笔迹仍保留。
- 每批事件自动写入本机 SQLite。保存失败时停止接收新绘画，保留待写数据并提供重试。离开 App 时尝试完成落盘；重新打开会恢复原画纸。
- “新画纸”保留旧作品，可从“我的画纸”重新打开。
- 混色先选择目标间色，工具区自动提供对应的两种原色。点颜色“蘸一份”，再在调色区涂抹；画过后仍可换色。余量用完后只搅拌，再点颜色才补充。旧活动点“新纸再试”使用新规则，旧画纸与全部笔迹保留。
- 横屏绘画采用左侧大画布、右侧说明与工具；工具较多时右侧可滚动。画纸比例和原始坐标不变。
- 任务说明与已显示的学习提示旁提供“朗读”。可手动停止，暂停、离开页面和切换任务时自动停止。普通话语音使用系统已安装的声音。
- 自由创作保存后可点“作品预览”；完成页显示作品缩略图，首页记录也有“作品预览”。原自由画纸顶部增加“预览”，不需要先导出。
- “导出”先完成保存，再生成 PNG、完整 JSON、采样 CSV 和 SHA-256 文件清单。导出页可调用系统分享面板，存储到“文件”。
- 首页三个模块用于独立演练。“新建研究访次”进入按参与者与访次组织的预实验流程；正式采集入口需现场验证与研究审批完成后另行冻结开放。
- 研究访次导出为 ZIP，包含研究事件、任务回答、首次有效记录、操作协助记录和每一张关联画纸。万相导出单独包含原画、原始笔迹、AI 生成图与调用记录。

## 构建与测试

需要完整 Xcode、iOS Simulator 运行环境和 XcodeGen。`InkStudy.xcodeproj` 已生成，直接用 Xcode 打开即可。工程配置来自 `project.yml`。

```sh
cd native/InkStudy
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project InkStudy.xcodeproj -scheme InkStudy \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InkStudyPrototype" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
```

核心单元测试不依赖模拟器：

```sh
cd native/InkStudy/Core
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

渲染、导出及保存恢复的 App 集成测试在 iPad 模拟器或真机运行：

```sh
cd native/InkStudy
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project InkStudy.xcodeproj -scheme InkStudy \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InkStudyPrototype" \
  -resultBundlePath test-output/app-tests.xcresult \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

测试中的压力曲线是明确构造的合成输入，用于检查渲染算法，不代表 Apple Pencil 真机验收。模拟器界面通过“手指预览”测试。

配对测试使用系统钥匙串，模拟器测试包必须签名；以上 `-` 为模拟器临时签名，不适用于真机。真机需要在本地选择自己的开发团队，仓库不携带维护者的 Team 配置或签名材料。

构建缓存使用 Xcode 的标准目录，避免模拟器因读取桌面目录下的构建产物而弹出额外的桌面文件访问请求。

## 记录与导出

App 沙盒中的 `Documents/InkStudy/drawings.sqlite` 是本机原始事件库。WAL 模式与 `synchronous=FULL` 用于事务持久化；事件 ID 与每张画纸的递增序号防止重试重复写入。只复制主数据库文件可能漏掉 WAL 中的数据，应使用 App 的完整导出。

`Documents/InkStudy/Exports/` 保存每次独立导出的副本：

| 文件 | 内容 |
| --- | --- |
| `artwork.png` | 当前可见作品，2400 × 1700，纯白背景；不包含界面文字 |
| `raw.json` | 画纸元数据、全部笔画、可见/重做 ID，以及最初采样、估计值修正、撤销/重做等完整事件 |
| `samples.csv` | 每个采样点最后收到的值；包含笔画是否可见、原始压力、最大压力、位置、时间和倾角 |
| `manifest.json` | 作品与原始笔迹数量、导出时间及其余三个文件的 SHA-256 |

将导出目录放在 Mac 后，可以独立核验文件及数据一致性：

```sh
node native/InkStudy/scripts/validate-export.mjs /path/to/export-directory
```

研究访次与万相体验的 ZIP 解压后分别核验：

```sh
node native/InkStudy/scripts/validate-research.mjs /path/to/unzipped-study
node native/InkStudy/scripts/validate-research.mjs /path/to/unzipped-generation --generation
```

研究核验会检查根清单、研究事件与画纸关联，再逐张核对 PNG、JSON、CSV 和原始事件；万相核验另检查原作快照、请求参数、任务编号和生成图哈希。

`raw.json` 的 `strokes` 是应用估计值修正后的笔迹；`events` 同时保留最初接收到的值和每一次修正。未收到最终修正的样本保留 `propertiesExpectingUpdates` 标记。旋转、后台切换和重启恢复会保留中断原因。普通画笔的屏幕与导出共用可变宽度几何，屏幕按每 256 点分块更新；混色按画纸保存的模型版本确定性重放，屏幕与导出共用算法；线稿在两种输出中均位于最上层。

时间分为两类：`uptime` 原样保存 `UITouch.timestamp`，单位为系统启动后的秒；`receivedAt`、`recordedAt` 和其他日历时间采用整数 UTC epoch 毫秒。压力、坐标、倾角和 `uptime` 不截断精度。跨系统重启不能直接相减 `uptime`。

普通画笔的粗细映射记录为 `width-v1`：

```text
p = force / maximumPossibleForce
diameter = brushSize * (0.12 + 0.88 * pow(clamp(p / 0.6, 0, 1), 0.85))
```

无有效压力时仅在显示层使用 0.35，不向记录中写入这个替代值。指示器只说明是否收到变化的压力信号；原型导出的压力验证状态为未验证，不直接作为正式实验压力指标。

混色画纸使用 `pigment-width-v1`，直径为 `brushSize * (0.65 + 0.35 * clamp(p / 0.6, 0, 1))`。新纸的 `background.pigmentModel` 为 `standard-palette-v4`，元数据 `schemaVersion` 为 2，`colorPaletteVersion` 为 `standard-rgb-v1-20260911`。旧纸继续使用原有 `spectral-palette-v3`、`spectral-wet-v2` 或缺省的 `ryb-pigment-v1`。内部表面宽 600 像素，按固定画纸比例显示与导出；原始坐标、压力和事件按原精度保存。

V3 和 V4 每次点击颜色产生新的 `BrushStyle.pigmentLoadID`，记入 `brushChanged` 和后续笔画样式。每份含 2,400 个参考网格质量单位，以 50 次有效落点释放，落点间距为 3 个画纸单位；同一 ID 跨笔画继续消耗，空 ID 表示只搅拌。未释放部分不进入调色盘。局部转移同时扣除来源、增加目标，不设颜料总量上限，不因后画而缩减原有颜料。显示透明度的上限不改变颜料数量。

V3 和 V4 导出在 `raw.json` 中附带 `pigmentMixing` 模型说明，并在 CSV 增加 `pigment_load_id` 列。保存指标包含各色实际落入调色盘的模型份数，以及按颜料量加权的配比方差；方差较小表示被测整张调色纸的配比更均匀。颜料份数是模型单位。撤销、重做、估计修正和重启均从同一原始记录恢复画面及余量。

V4 的屏幕颜色按六个给定 sRGB 色点插值：三原色是配比三角形的顶点，三间色是对应等量配比的中点。局部实际配比决定颜色，等量且覆盖充分时得到指定间色；边缘与白纸混合。配对由目标自动确定，配对回答表示预设组合，不再表示儿童自主选择原色。新访次配置也保存 `colorPaletteVersion`；旧访次的色卡沿用旧值。

显示刷新由 `CADisplayLink` 合并到每秒最多 60 次，单一后台 worker 处理绘制。每 32 个采样保存渲染检查点，最多保留 8 个；修正回退到最近的有效检查点，较早笔迹的修正会使其后的缓存失效。后台 CPU 计算与 Core Animation 合成分离，不在 Pencil 回调中生成位图。

旧 V2、V3 混色使用 MIT 许可的 [Spectral.js](https://github.com/rvanwijnen/spectral.js) 离线查找表。原始依赖与许可证在 `ThirdParty/Spectral/`。0911V2 将相同的表编入 `SpectralLookupTable.swift`，绘画和恢复时不再从资源文件强制读取；原表与许可继续随 Core 资源打包供旧纸回放。生成命令为 `node scripts/generate-pigment-lut.mjs`，四种模型的性能对照为 `swift run -c release --package-path Core PigmentBenchmark`。

Xcode 每次构建后运行 `scripts/verify-app-package.sh`，逐字节核对实际 App 内的状态模型、颜料表和许可证。任一文件缺失或过期，构建失败。发布归档中的 `.app` 还须单独运行该检查和 `codesign --verify --deep --strict`，然后验证最终安装包的启动与上次画纸恢复。

## 真机验收

1. 在 Xcode 的 Signing & Capabilities 选择自己的开发团队，将已解锁并信任这台 Mac 的 iPad 选为运行设备。首次开发运行可能需要在 iPad 上开启开发者模式。
2. 用支持压感的 Pencil，保持笔刷宽度不变，连续由轻到重再变轻。检查线条粗细、原始 `force`、`maximumPossibleForce` 和估计更新记录。
3. 依次选六色及最细/最粗笔刷，连续绘画；检查掌触不会产生额外笔画。
4. 撤销、重做，再撤销后另画一笔，核对画面与原始笔画数量。
5. 绘画后离开 App、重新打开，检查作品、颜色、宽度和撤销栈恢复；另测画到一半中断的恢复。
6. 导出到“文件”，打开 PNG、JSON 和 CSV，复核 manifest 哈希、笔迹数量及压力数据。

完整研究入口的本机绘画、记录与既有本地 C 组提示不依赖网络。独立提示演练入口可在成人/虚构示例同意和配对后调用 DeepSeek；不可用时保留本地回退。万相体验在用户确认上传后调用独立图像服务，安装包不包含两家服务的 API Key。系统设备备份由 iPad 的备份设置控制。

## 实现依据

- [Apple：Handling input from Apple Pencil](https://developer.apple.com/documentation/uikit/handling-input-from-apple-pencil)
- [Apple：Getting high-fidelity input with coalesced touches](https://developer.apple.com/documentation/uikit/getting-high-fidelity-input-with-coalesced-touches)
- [Apple：Minimizing latency with predicted touches](https://developer.apple.com/documentation/uikit/minimizing-latency-with-predicted-touches)
- [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)

原型立即读取合并触摸，处理 Pencil 估计属性的后续修正；预测点不进入原始记录。
