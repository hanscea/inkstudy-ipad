# 万相服务端

Node.js 22 及以上，不依赖第三方 npm 包。API Key 只从服务端环境变量 `DASHSCOPE_API_KEY` 或指定本地文件读取。iPad 仅保存与本服务配对的设备令牌。

## 本机启动

在仓库根目录执行：

```sh
node native/InkStudy/Bridge/cli.mjs configure --key-file /absolute/path/to/key.txt
node native/InkStudy/Bridge/cli.mjs serve --host 0.0.0.0 --port 8787
```

本地文件须为 UTF-8 文本，含一个万相 Key，可以是单独的 Key 或 `DASHSCOPE_API_KEY=...`，支持旧式 `sk-` 和点分隔格式；检测到多个候选值会拒绝配置。配置仅保存文件路径，不复制或打印 Key。也可直接通过环境变量运行服务。默认运行数据目录为 `~/Library/Application Support/InkStudyBridge`，文件使用仅当前用户可读写的权限。

新终端中生成一次性配对码：

```sh
node native/InkStudy/Bridge/cli.mjs pair
```

iPad 与 Mac 在同一可信局域网中，在 App 的“万相草图体验 → 连接设置”填服务端打印的局域网地址及 8 位配对码。配对码有效 10 分钟、只能使用一次。不要在 App 中输入万相 API Key。模拟器可使用 `http://127.0.0.1:8787`。

Mac 必须保持服务运行。默认只绑定本机；`--host 0.0.0.0` 用于局域网测试，不配置路由器公网端口转发。HTTP 只用于成人或虚构图像测试，研究参与者图像在原生客户端中要求 HTTPS。拒绝局域网权限后，可以在 iPad 系统设置中调整；App 不会绕过权限或证书校验。

## 调用与限制

固定模型为 `wanx2.1-imageedit`，功能为 `doodle`，参数为 `is_sketch=true`、`n=1`、`watermark=true`，随机种子随每个本地任务保存。只上传 PNG 和描述，不把原始压力、研究回答或访谈传到万相。服务端仍会保存原 PNG、请求配置、任务编号、状态和输出图像，须按项目的数据保留规则管理。

默认每日最多接收 10 个新任务，按 UTC 日期计数；最多保留 2 个排队或处理中任务。每日上限是本服务的请求控制，不是阿里云账户余额或费用保证。可用 `configure --daily-limit 数值` 调整，重启后生效。单次请求仅一张，调用费用、试用额度与有效期以自己的百炼账户和[万相产品文档](https://help.aliyun.com/zh/model-studio/wanx-image-edit)为准。

输入要求为 512–4096 像素、PNG 不超过 10 MB。服务端验证文件结构与 CRC，拒绝用户传入的远程图片地址。模型端点只允许北京官方地址，生成图下载只允许官方结果域名、可信 HTTPS，且拒绝重定向。默认使用仍受支持的 `https://dashscope.aliyuncs.com/api/v1`；也可配置自己的北京业务空间端点。[接口文档](https://help.aliyun.com/zh/model-studio/wanx-image-edit-api-reference)

## 断网与恢复

客户端先保存原画快照和固定任务 UUID。重试先查询同一 UUID；只有服务端明确未接收本任务时才用同一 UUID 发送请求。服务端在调用万相前将任务写为 `SUBMITTING`，有云端任务编号后只查询和下载，不再次生成。

如果提交时连接中断且没有获得云端任务编号，状态为 `SUBMISSION_UNKNOWN`。不要反复创建新任务。先在百炼控制台核对该次请求；找到对应的云端任务编号后，由研究者执行：

```sh
node native/InkStudy/Bridge/cli.mjs attach-task --job 本地任务UUID --provider-task-id 已核对的万相任务UUID
```

这个操作只查询并关联已有云端任务。随后在 App 点击“继续查询 / 取回图片”。若控制台确认没有创建任务，可由研究者决定另建一次；程序不会把不确定提交自动当作失败重发。万相任务与结果链接有 24 小时查询/下载窗口，服务端会及时取回成功图像。[接口文档](https://help.aliyun.com/zh/model-studio/wanx-image-edit-api-reference)

服务端配对、任务和原图目录应一起备份；运行中不要删除 `runtime/jobs` 或更换为空数据库，否则会失去幂等和归属记录。`status` 只打印配置状态、设备编号和任务摘要，不打印任何令牌或 API Key。

同一运行目录使用独占进程锁，不能同时启动两个服务，即使端口不同也不允许，以免重复提交排队任务。正常退出会释放锁。异常断电或强制结束后，先确认原服务已退出，再运行以下命令并重启服务；该命令不会移除仍在运行的进程所持有的锁：

```sh
node native/InkStudy/Bridge/cli.mjs recover-runtime
```

## 研究参与者放行

App 会检查该参与者的 V1a、V1b、V2、V3、V4、V5、V6、V7 全部完成。服务端还要求研究者用八次完整导出的 `study.json` 核准，客户端自行传入 `allVisitsCompleted` 无效：

```sh
node native/InkStudy/Bridge/cli.mjs approve-research --participant P01 \
  --study /exports/V1a/study.json --study /exports/V1b/study.json \
  --study /exports/V2/study.json --study /exports/V3/study.json \
  --study /exports/V4/study.json --study /exports/V5/study.json \
  --study /exports/V6/study.json --study /exports/V7/study.json
```

各文件旁必须有导出根 `manifest.json`，哈希、参与者、完成状态、顺序和组别须一致，不能含缺失画纸。正式采集当前未开放；上述放行仅用于已获相应授权的预实验测量后体验。

## 部署与管理

代码可部署在支持 Node 22、持久磁盘和可信 HTTPS 反向代理的服务器上。以非特权账号运行，Key 通过服务端秘密配置注入，外部只开放 HTTPS。保留默认鉴权、每日限制与持久化目录；不要把本目录当静态网站公开。当前代码不自动购买主机、注册域名、开公网隧道或自动安装开机服务。

```sh
node native/InkStudy/Bridge/cli.mjs status
node native/InkStudy/Bridge/cli.mjs revoke-device --device 已配对设备UUID
node --test native/InkStudy/Bridge/bridge.test.mjs
```

接口包括一次性配对、带令牌的状态检查、同 UUID 幂等提交、任务查询和生成图下载。浏览器 Origin 请求被拒绝；原生令牌按设备隔离，轮换和撤销不删除历史文件。部署到 HTTPS 后，在 App 重新配对到该 HTTPS 地址，旧地址的令牌不会自动转发到新服务器。
