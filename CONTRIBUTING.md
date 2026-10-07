# 协作说明

## 获取权限与提交修改

本仓库公开，查看和克隆不需要邀请。直接向本仓库推送需要维护者授予写入权限；没有写入权限时，先 Fork 到自己的账号，再从 Fork 发起 Pull Request。不要共享 GitHub 登录、Apple 签名身份或云端 API Key。

```sh
git clone https://github.com/hanscea/inkstudy-ipad.git
cd inkstudy-ipad
git switch -c fix/short-description
```

完成修改后，检查差异和待提交文件，提交自己的改动，再发起 Pull Request。不要直接覆盖其他人的分支或强制推送 `main`。

```sh
git diff --check
git status --short
git add path/to/changed-file
git diff --cached
git commit -m "Describe the change"
git push -u origin fix/short-description
```

上述推送命令用于已有写入权限的合作者。使用 Fork 时，克隆自己账号下的仓库，使 `origin` 指向自己的 Fork，再推送分支并向 `hanscea/inkstudy-ipad` 提交 PR。

PR 说明包含修改目的、涉及的 App 入口、测试命令和结果。界面问题可以附使用虚构数据制作的截图；不要附真实儿童作品、身份信息、配对码或包含凭据的终端画面。

## 最低检查

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path native/InkStudy/Core
node --test native/InkStudy/Bridge/bridge.test.mjs \
  native/InkStudy/Bridge/hints.test.mjs
```

修改 `project.yml` 后运行 `xcodegen generate`，同时提交生成的工程和共享 Schemes。两种 App 共用 `App/`，修改公共视图、记录或渲染代码后应分别构建 `InkStudy` 与 `InkStudyHints`。配对测试依赖钥匙串，模拟器集成测试需要临时签名，命令见[验证说明](docs/collaboration/VALIDATION.md)。

真实 API 测试由维护者单独安排，使用成人或虚构材料并确认调用费用。不要让常规测试自动读取开发者的密钥文件。

## 数据与版本约束

- 保留原始笔迹、估计值修正、中断、撤销和首次技术有效试次。不要用更好的后续结果覆盖测量记录。
- 修改混色显示、压力目标、提示库、候选规则或模型配置时，检查对应版本字段、旧记录回放和测试。涉及研究条件的变化先与研究负责人确认。
- 新提示预览与完整研究入口分别记录；不要把预览版云端策略当作所有 C 组访次的既有逻辑。
- 保持 B、C 组预览提示的呈现、次数和间隔约束一致。教学策略变化不能混入纯界面修复。
- 私有仓库也不存放数据集、画作导出、设备备份、密钥、令牌、签名材料或个人运行配置。
- 保留 `ThirdParty/Spectral/` 与 Core 中的许可证和查找表；旧画纸回放依赖这些资源。

## 仓库范围

根 `.gitignore` 使用允许列表，只发布当前原生工程和协作文档。新建顶层目录需要明确加入规则。不要使用 `git add -f` 强行提交被忽略的数据或生成文件。

本次初始提交是最新源码快照；后续用正常 Git 提交管理改动。发布构建前记录对应 commit、App 版本、研究协议、提示库与模型配置。需要可安装包时，由维护者另行安排签名和分发，不把开发证书提交到 Git。
