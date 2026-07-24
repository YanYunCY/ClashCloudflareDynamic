# Clash Cloudflare Dynamic

Windows 上的 Cloudflare Anycast 地址动态发现与 Mihomo/Clash Verge Rev 自动优选工具。

它从 Cloudflare 官方 IPv4 网段抽样候选，先按用户选择的节点端口做 TCP 初筛，再通过用户自己的 Mihomo 节点模板验证真实协议、TLS 和传输链路，执行多轮延迟与下载测速，并在防抖条件满足后更新 provider 和切换节点。

> 本项目不提供代理服务、节点账号或认证信息。请仅使用你拥有或获授权使用的节点、域名和凭据。

## 源码与部署包

这个 Git 仓库保存的是开发源码，不是 `%LOCALAPPDATA%` 中的运行目录。源码、测试、Windows 脚本和公开配置分别维护：

```text
src/clash_cloudflare_dynamic/  Python 核心源码
scripts/windows/               安装、通知、任务和卸载脚本
tests/python/                  Python 单元与回归测试
tests/windows/                 Windows PowerShell 隔离测试
config/                        无凭据的运行资源
examples/                      无凭据的配置示例
tools/build_release.py         部署包构建器
tools/privacy_check.py         发布前隐私检查
```

`python tools/build_release.py` 会根据显式白名单生成 `dist/ClashCloudflareDynamic.zip`。压缩包采用便于 Windows 计划任务运行的平铺结构；`dist/` 不进入 Git。安装后的文件结构与源码仓库结构因此是两套明确分离的布局。

`v1.3.0` 已把 Windows 安装器迁移为 WPF 单页界面：主配置位于左侧，脱敏实时摘要位于右侧，本地 Mihomo 连接设置默认折叠。界面支持“跟随系统 / 浅色 / 深色”，使用系统强调色、轻量设置卡片和响应式布局；窄窗口会收起摘要，表单可独立滚动且底部操作栏保持固定。安装器也针对 Per-Monitor V2 DPI、ClearType 和布局像素对齐做了专门处理。

`v1.3.2` 补齐正式测速公平调度、历史稳定性评分、严格正式池准入和按模式运行心跳；`v1.3.1` 的通知 HTML 数量上限与日志轮转仍然保留。

## 版本与下载

具体版本的 Release 页面只展示该版本；全部历史版本请打开 [Releases 列表](https://github.com/YanYunCY/ClashCloudflareDynamic/releases)。

| 版本 | 状态 | 主要变化 | 下载 |
| --- | --- | --- | --- |
| `v1.3.2` | 最新稳定版 | 交错三轮测速、历史稳定性、正式池准入、扫描心跳 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.2) |
| `v1.3.1` | 维护版本 | 通知报告数量上限、通知与健康监控日志轮转 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.1) |
| `v1.3.0` | 历史稳定版 | WPF 单页安装器、三种外观、实时脱敏摘要与响应式布局 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.0) |
| `v1.2.0` | 历史稳定版 | 三步现代安装向导、脱敏确认页、小屏与无障碍改进 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.2.0) |
| `v1.1.0` | 历史稳定版 | Release 图形安装向导、升级保留与事务重配置 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.1.0) |
| `v1.0.2` | 历史稳定版 | 阶段漏斗、失败与名额未入选分离、失败报告 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.2) |
| `v1.0.1` | 历史稳定版 | 协议与端口写入 CSV、决策 JSON 和报告 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.1) |
| `v1.0.0` | 已被取代 | 首个公开版本，仅建议用于历史查阅 | [Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.0) |

逐版本变更记录见 [CHANGELOG.md](https://github.com/YanYunCY/ClashCloudflareDynamic/blob/main/CHANGELOG.md)。

## 主要功能

- 每 30 分钟轻量扫描，默认最多发现 200 个新地址；
- 每 6 小时深度扫描约 5000 个新地址；
- SQLite 避免短期重复抽样，并自动维护历史；
- 真实代理链路验证，不以裸 IP 的 HTTP 测速代替节点验证；
- VMess、VLESS、Trojan 示例和自定义 Mihomo 节点模板；
- Release 内置可双击的 Windows 图形安装向导；
- TCP 初筛自动跟随节点模板端口，不再写死为 443；
- 发现、粗测、正式测速 CSV、决策 JSON 和通知报告记录协议与端口；
- 每个最终候选连续测试 3 次，记录原始值、平均值、标准差和 CV；
- 在最高平均速度 95% 的高速组中选择平均延迟最低节点；
- provider 原子更新、`.last-good` 回滚和 Mihomo 状态确认；
- `pythonw.exe` 后台任务，不创建可见命令行窗口；
- 静音高优先级 Windows 通知，点击查看独立 HTML 报告；
- 日志轮转、通知报告数量上限、备份清理、数据库损坏备份与恢复；
- 深扫前台繁忙延后和独立任务健康监控。

## 运行要求

- Windows 10/11；
- Python 3.10 或更高版本，并包含同目录的 `pythonw.exe`；
- Clash Verge Rev；
- Mihomo REST API 可从本机访问；
- `curl.exe`；
- 一个你有权使用的代理节点模板。模板必须包含 Mihomo 节点所需认证、`port` 和传输参数，程序只替换 `name` 与 `server`，其余字段原样保留。Mihomo 的 `type`、`server` 和 `port` 是代理节点通用字段，具体协议字段以 [Mihomo 官方文档](https://wiki.metacubex.one/en/config/proxies/) 为准。

默认地址：

- Mihomo API：`http://127.0.0.1:9090`
- mixed proxy：`http://127.0.0.1:7890`
- 安装目录：`%LOCALAPPDATA%\ClashCloudflareDynamic`
- provider：`%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\providers\ClashCloudflareDynamic`

provider 目录位于 Clash Verge Rev 的 SAFE_PATHS 内，不应改回 `%LOCALAPPDATA%`。

## Release 一键安装

普通用户推荐使用图形向导：

1. 从 [v1.3.2 Release](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.2) 下载 `ClashCloudflareDynamic.zip`；
2. 完整解压 ZIP，不要直接在压缩包预览窗口中运行；
3. 双击根目录的 `Install.cmd`；
4. 选择 VMess、VLESS、Trojan 或自定义 Mihomo 模板，填写端口、API 和节点参数；
5. 按下方“Clash Verge Rev 中的必要设置”启用外部控制，然后导入向导显示的 YAML，并选择 `节点选择 → 自动选择`。

向导不会下载或执行网络上的安装脚本。UUID、密码和 API secret 使用掩码输入，只写入受控临时目录和本机安装目录；临时配置在安装成功或失败后都会清理，不会留在 Release 解压目录。

检测到已有安装时：

- 选择“保留配置并升级（推荐）”：升级或修复程序，保留现有协议、端口和凭据；
- 选择“重新填写节点参数”：安装器先事务备份，再替换设置、重建 Clash YAML，并用原 IP 列表重建 provider；
- 选择“取消”：不修改安装。

这是引导式一键安装，仍要求本机已安装 Python 3.10+、`pythonw.exe` 和 Clash Verge Rev。项目尚未使用代码签名证书，因此 Windows 可能显示未知发布者提示；请只从本仓库 Release 下载，并核对 Release 中公布的 SHA-256。

## Clash Verge Rev 中的必要设置

安装脚本不能代替用户修改 Clash Verge Rev 的应用设置。首次使用时必须启用 Mihomo 外部控制，否则程序无法通过 REST API 读取 provider、测试节点或切换“自动选择”：

1. 打开 Clash Verge Rev，进入 `设置 → Clash 设置`（不同版本可能显示为 Mihomo 内核设置）；
2. 找到并打开 `外部控制`；
3. 外部控制地址建议保持为 `127.0.0.1:9090`，不要绑定到 `0.0.0.0` 或公网地址；
4. 如果 Clash Verge Rev 设置了外部控制密钥，请在安装向导的“Mihomo API 密钥”中填写完全相同的值；没有设置密钥时两边都留空；
5. 如果使用其他端口，请同时把安装向导中的 Mihomo API 改为对应地址，例如 `http://127.0.0.1:9191`；
6. 保存设置，并按 Clash Verge Rev 提示重载配置或重启 Mihomo 内核；
7. 进入配置页面，导入并启用：

   ```text
   %LOCALAPPDATA%\ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml
   ```

8. 进入代理页面，在 `节点选择` 中选择 `自动选择`；
9. 双击安装目录中的 `diagnose.bat`。只有显示“Mihomo API：正常”“provider SAFE_PATHS：正常”和“节点选择当前策略：自动选择”后，自动扫描与切换才算配置完成。

外部控制只需要允许本机访问。不要为了排查连接问题关闭密钥、监听所有网卡或把控制端口暴露到局域网/公网；如果诊断显示连接被拒绝，优先检查“外部控制”开关、端口以及 Mihomo 内核是否已经重新加载。

## 手动安装（高级用户与开发者）

开发者从源码安装时，以下命令均在仓库根目录运行；部署包用户则去掉路径中的 `scripts\windows\`。

1. 选择协议和端口并创建本地配置。例如：

   ```powershell
   # VMess + WebSocket + TLS，端口 443
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol vmess -Port 443

   # VLESS + WebSocket + TLS，端口 8443
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol vless -Port 8443

   # Trojan + WebSocket，端口 2053
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -Protocol trojan -Port 2053

   # 其他 Mihomo 节点类型：复制自定义模板，可选覆盖其端口
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup.ps1 -NodeTemplatePath .\node_template.local.json -Port 2096
   ```

   省略 `-Port` 时使用模板中的端口。一次安装选择一个入口端口；TCP 初筛和最终节点都会使用同一个端口。已有配置只想换端口时，可直接运行 `setup.ps1 -Port 8443`：它会先备份节点模板，只修改端口，不覆盖协议、认证或 `settings.json`。要替换整个协议模板但保留 Mihomo API 设置，使用 `-ReplaceNodeTemplate -Protocol vless`；旧节点模板同样会先备份。`*.local.json` 已被 Git 忽略，但自定义模板仍可能包含真实凭据，发布前必须运行隐私检查。

2. 编辑 `settings.json`：

   - `controller`：Mihomo REST API；
   - `secret`：REST API 密钥，没有则留空；
   - `mixed_proxy`：本地 mixed HTTP 代理地址。

3. 编辑 `node_template.json`，把 `replace-with-your-domain.example` 同时替换为你自己的 SNI/Host 域名，并替换示例 UUID/密码和传输路径，再次核对 `type` 与 `port`。公开源码和 Release 只包含保留的占位域名，不包含维护者或其他用户的真实域名；安装器也会拒绝使用 `.example`、`example.com`、`example.net` 或 `example.org` 生成实际配置。

   Cloudflare 普通代理当前支持的 HTTPS 入口端口为 `443`、`2053`、`2083`、`2087`、`2096`、`8443`。端口是否真的适用于你的节点，还取决于域名、源站和服务端配置；不能因为某个 Cloudflare IP 的端口可建立 TCP 连接，就认定真实代理协议可用。项目仍会用完整节点链路淘汰假阳性。详见 [Cloudflare 官方端口说明](https://developers.cloudflare.com/fundamentals/reference/network-ports/)。

   协议也不是任意替换后都能经过普通 CDN。VMess/VLESS/Trojan 的 WS、HTTP、gRPC 等部署可以按实际服务端模板配置；纯 TCP、QUIC/UDP 或其他非 HTTP(S) 传输通常需要不同的 Cloudflare 产品或根本不适用。自定义模板必须满足“只替换 `server` 为 Cloudflare IP 后仍能凭 SNI/Host 等字段到达同一服务”的条件。

4. 安装推荐的混合任务：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\windows\install_hybrid_5000.ps1
   ```

   安装器会在创建目录、备份或任务之前检查本地配置；仍含零 UUID、示例密码、保留的示例域名或示例 WebSocket 路径时会直接拒绝安装。

5. 在 Clash Verge Rev 导入：

   ```text
   %LOCALAPPDATA%\ClashCloudflareDynamic\clash_cloudflare_dynamic_verge_safe.yaml
   ```

   然后选择 `节点选择 → 自动选择`。

6. 诊断与手动轻扫：

   ```powershell
   python "$env:LOCALAPPDATA\ClashCloudflareDynamic\dynamic_selector.py" --diagnose
   python "$env:LOCALAPPDATA\ClashCloudflareDynamic\dynamic_selector.py" --quick
   ```

## 配置安全

`settings.json`、`node_template.json`、生成的 Clash YAML、provider、日志、数据库和通知报告均已列入 `.gitignore`。不要使用 `git add -f` 强制提交它们。

公开的 `config.template.yaml` 不包含 SNI、Host、UUID 或节点密码。SNI/Host 只来自当前用户在安装向导中填写的域名，并写入该用户本机的 `node_template.json` 和 provider；这是 Mihomo 通过 Cloudflare IP 定向到用户自己节点域名所必需的数据，不会上传到 GitHub。公开的三个节点示例统一使用 `replace-with-your-domain.example`，不能直接安装或连接。

隐私检查器也会检查被 Git 忽略但仍留在工作目录中的本地配置，并且只报告文件名和风险类别，不打印匹配到的凭据。制作 Release 压缩包时应从已审核的 Git 提交生成归档，不要直接压缩正在运行或测试过的工作目录。

Git 已跟踪文件也会单独检查；即使使用 `git add -f`，备份、日志、provider 或本地配置进入 Git 后仍会导致隐私检查失败。

提交或发布前运行：

```powershell
python .\tools\privacy_check.py
git status --ignored --short
```

## 选优规则

1. 候选必须通过节点模板所选端口的 TCP 初筛；
2. provider 热更新后通过真实代理链路做 3 轮延迟测试；
3. 低延迟、历史高速和随机探索候选进入速度粗测；
4. 正式候选按轮交错下载测速 3 次，避免某个节点连续占用同一时间窗口；
5. 任意一次失败、下载量不足或速度 CV 超过阈值时淘汰；
6. 达到本轮最高平均速度 `fast_speed_ratio` 的节点进入高速组；
7. 高速组内按三轮平均延迟选择节点；
8. 历史速度按每个 IP 最近 `historical_speed_samples_per_ip` 次结果加权，并使用 `historical_speed_stability_penalty` 惩罚波动；
9. 正式池默认只新增通过正式下载测速的节点，旧正式池有效节点继续保留；只有显式设置 `allow_delay_only_pool_backfill: true` 才允许仅通过延迟测试的新节点补池；
10. 正常切换受冷却时间控制，失效节点可以立即替换。

## 通知与 HTML 报告中的阶段漏斗

Windows 通知和点击后打开的 HTML 报告按“候选 → TCP 可达 → 真实代理链路 → 速度粗测 → 正式三轮测速”展示本轮漏斗。相邻阶段的数量差不能一律理解为失败：发现池、速度粗测池和正式测速池都有数量上限，候选可能已经通过前一阶段，只是因当轮配额、排序或抽样策略未进入下一阶段；这种情况属于“未入选”，不是链路或测速失败。

- `各阶段失败 IP` 是本轮各验证阶段确认失败的 IP 总数，例如 TCP 不可达、真实代理链路失败、速度粗测失败或正式三轮测速失败；不包含仅因配额未入选的候选。
- `名额未入选` 使用各阶段实际选择名单计算；极少数已被选择但因无效节点名等内部原因没有执行测试的项，会单列为 `已选未执行`，不会被误算成配额未入选。
- HTML 中的 `正式三轮测速淘汰` 只列出已经进入正式三轮下载测速、但因测试轮次失败、下载量不足或速度 CV 超限而未通过的节点。没有进入正式测速配额的节点不会出现在该表中。
- `正式尝试` 是实际进入正式三轮测速的节点数，`正式通过` 是其中完整通过正式测速质量条件的节点数；二者之差才对应正式测速阶段的淘汰数量。
- `高速组` 是正式测速通过后的二次选优标签。速度低于当轮 `fast_speed_ratio` 门槛而位于高速组外，只表示没有进入最终的低延迟竞争组，不代表节点失败，也不会列入 `正式测速淘汰`。

扫描在中途失败时，通知会附带截至失败阶段已经取得的部分漏斗，并生成可点击的失败 HTML 报告；尚未运行的阶段保持为零，同时以失败阶段和错误原因说明扫描停止位置。

## 后台任务

- `Clash Cloudflare Light Scan 30min`
- `Clash Cloudflare Deep Scan 5000 6h`
- `Clash Cloudflare Health Monitor 30min`

扫描和健康监控均使用 `pythonw.exe`。健康监控启动器通过 `CREATE_NO_WINDOW` 调用 PowerShell，因此不会弹出空命令行窗口。轻量和深度扫描分别写入 `logs/last_run_light.json` 与 `logs/last_run_deep.json`，区分 `success`、`skipped`、`failed`；健康监控只把有效成功心跳记为最近成功，并检查正式测速通过数和正式池大小。

## 通知报告与日志维护

每条 Windows 通知都绑定独立 HTML，默认最多保留最新 100 份且不超过 30 天；任一条件超限时删除最旧报告。可用 `notification_report_max_files` 和 `notification_report_retention_days` 调整。主扫描日志默认达到 5 MB 后轮转并保留 3 份备份；通知投递日志、健康监控日志和健康监控启动器错误日志也会轮转，不会无限追加。通知投递日志默认每份 1 MB、保留 2 份备份，可用 `notification_delivery_log_max_bytes` 和 `notification_delivery_log_backups` 调整。

## 可选的激进模式

如确实需要每 30 分钟执行一次 5000 地址深扫，可在完成普通安装后运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\install_aggressive_5000_30min.ps1
```

这会显著增加 TCP 连接数和测速流量，通常不建议长期启用。重新运行 `install_hybrid_5000.ps1` 可恢复推荐的混合模式。

## 卸载

源码仓库中运行时，默认只移除计划任务和通知快捷方式，保留程序、日志及 provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\uninstall.ps1
```

先在 Clash Verge Rev 中切换到其他配置后，才应使用 `-RemoveData` 删除安装目录和 provider：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\uninstall.ps1 -RemoveData
```

## 隐私

程序没有遥测或远程日志上报。网络请求仅用于：

- 获取 Cloudflare 官方 IPv4 网段；
- Mihomo API 与本地代理；
- 配置的延迟测试和下载测速 URL；
- 用户授权节点的真实代理链路。

详细安全说明见 [SECURITY.md](SECURITY.md)。

## 开发与测试

```powershell
python .\tools\privacy_check.py
python .\tools\build_release.py
Get-ChildItem .\src\clash_cloudflare_dynamic\*.py, .\tools\*.py | ForEach-Object { python -m py_compile $_.FullName }
$env:PYTHONPATH = Join-Path $PWD "src"
python -W error::ResourceWarning -m unittest discover -s .\tests\python -p "test_*.py" -v
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_wizard.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_install_hybrid.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\windows\test_uninstall.ps1
```

GitHub Actions 会在 Windows 上执行同一组检查，并把由已审查源码生成的 `ClashCloudflareDynamic.zip` 作为工作流产物上传。

## 免责声明

Cloudflare Anycast 性能会随地区、运营商和时间变化。本软件不保证永久最快地址，也不保证第三方代理服务可用。请遵守当地法律、服务条款和网络使用政策。

## License

[MIT](LICENSE)
