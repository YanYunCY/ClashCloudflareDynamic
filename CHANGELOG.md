# 版本历史

全部安装包和 GitHub 自动生成的源码归档见 [Releases 列表](https://github.com/YanYunCY/ClashCloudflareDynamic/releases)。

## [v1.4.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.4.0) — 2026-08-08

- 正式下载吞吐改为按响应体传输时间计算，排除 TTFB 对短样本的系统性压低，同时保留含连接阶段的全程平均速度供诊断；
- 深度扫描默认提高为每次 20 MB、单次超时 60 秒，降低慢启动和小样本噪声；
- 轻量扫描新增独立的 `quick_speed_test_bytes=3000000` 与 `quick_speed_timeout_seconds=20`，避免深扫参数放大半小时任务流量；
- 正式测速与速度粗测保留真实链路预热，三次样本、平均值、标准差与 CV 的准入规则不变；
- Release 工作流新增标签/CHANGELOG 严格匹配、JSON/BOM、Python 编译与单测、PowerShell 解析、Windows 安装隔离测试及隐私检查门禁，验证未通过时不再创建 Release；
- README 安装入口改为 `releases/latest`，避免继续指向历史版本。

## [v1.3.7](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.7) — 2026-07-27

- 修复 Cloudflare 官方网段缓存文件写入非原子：改用 temp + os.replace 模式，进程在写入途中崩溃不再产生残留的截断缓存文件；
- 修复 `save_json_atomic` 在写入失败时遗留 `.tmp` 临时文件：加 finally 清理，与通知报告写入保持一致。

Windows 部署包 SHA-256：

```text
C9AE5F47D5F972448AA987750A42C7DBC4ADA15F14A4330FE83123F8B0F58573
```

## [v1.3.6](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.6) — 2026-07-26

- 修复最小切换间隔边界条件：调度器以 30 分钟触发但扫描本身耗时数分钟，导致两次决策之间的实际间隔略小于 0.5 小时，满足条件的候选仍被拦截；新增 90 秒宽限期（`switch_interval_grace_seconds`，默认 90）吸收调度抖动，可设为 0 恢复严格行为。

Windows 部署包 SHA-256：

```text
D558D350BF864117922A7435FF331F68FAA20D3681CA69A3444969793A7F8646
```

## [v1.3.5](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.5) — 2026-07-25

- 新增深度扫描强制执行机制：当深扫连续因前台繁忙被跳过超过阈值（默认 8 小时，可通过 `deep_scan_force_after_skipped_hours` 调整）后，下一次触发将忽略前台状态强制执行，并推送通知；可通过 `deep_scan_force_enabled: false` 完全禁用。

## [v1.3.4](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.4) — 2026-07-24

- 新增 `tools/sync_check.py` 三方代码同步对账工具与 `config/sync_markers.json` 特征清单，检测开源版、部署版与镜像之间的关键修复漏同步；
- 扫描历史默认保留期从 90 天降为 30 天，稳态数据库体积显著下降；单次清理删除超过阈值（默认 5000 行，可通过 `vacuum_after_deleted_rows` 调整）后自动执行 VACUUM 回收文件空间；
- 主程序与对账工具入口强制 stdout/stderr 使用 UTF-8，修复 GBK 控制台下中文输出乱码；
- 隐私检查从"仅检查已知文本后缀"反转为"默认检查一切、显式跳过已知二进制"，未知二进制文件会被显式标注，消除新增文件类型的检测盲区；
- README 顶部新增 CI/Release/License 徽章与英文 TL;DR；
- 新增 issue 模板（bug 报告、功能请求）与 PR 模板，日志粘贴处提醒先脱敏。

Windows 部署包 SHA-256：

```text
3727F02CA2E3A0A1A808BC7C418A9D494C7AC4868AAF42C3146BCD1CE5E464A3
```

## [v1.3.3](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.3) — 2026-07-24

- 速度粗测阶段对单节点选择确认超时增加容错，失败节点跳过继续测试而不再中止整轮扫描；
- Mihomo 控制面 API 请求显式禁用系统和环境代理，避免在用户设置全局代理时产生自我干扰；
- 构建发布包时固定 ZipInfo.create_system 为 0，确保 Windows/Linux/macOS 构建字节级一致；
- backups/ 清理白名单补充 6 个缺失前缀，根目录散落备份文件新增保留策略（每类保留最新 3 份且不超 30 天）；
- 新增 `.github/workflows/release.yml` 自动发布流程，tag push 自动触发测试、构建、生成 SHA-256 校验文件并创建 GitHub Release；
- CI workflow 中 Actions 引用固定到具体 commit SHA 以防供应链风险；
- CHANGELOG 为 v1.1.0 至 v1.3.2 补充 SHA-256 哈希值记录。

## [v1.3.2](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.2) — 2026-07-24

- 正式下载测速改为跨候选按轮交错执行三次，降低不同时段网络波动对节点比较的偏差；
- 严格模式下某节点失败后只跳过该节点后续轮次，不影响其他候选完成三轮测试；
- 历史速度候选使用每个 IP 最近 5 次结果的加权评分，并按速度变异系数惩罚不稳定记录；
- 正式池默认只新增通过正式下载测速的节点，延迟通过但未完成下载测速的新节点不再自动补池；
- 轻量和深度扫描分别记录 `success`、`skipped`、`failed` 心跳，健康监控校验最近成功结果的正式测速通过数与正式池大小；
- 保留 v1.3.1 的通知报告数量上限、通知日志和健康监控日志轮转。

Windows 部署包 SHA-256：

```text
28D9B18F0C76477E08702A90E2CD80CCE3F9D7B5777CD327B7E352339AF83A32
```

## [v1.3.1](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.1) — 2026-07-24

- 通知 HTML 在保留天数之外新增最大文件数限制，默认只保留最新 100 份，避免半小时任务长期产生上千个报告；
- `notification_delivery.log` 和健康监控启动器错误日志新增按大小轮转，默认每份 1 MB、保留 2 份备份；
- 通知脚本会一并清理超过一天的残留 HTML 临时文件，扫描、健康监控与通知脚本共用相同的保留上限。

Windows 部署包 SHA-256：

```text
C7D2F62B290E20E96A44DD781CDB5D08EF1D9CCB38E834543E303743C2A9C1CA
```

## [v1.3.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.3.0) — 2026-07-24

- Windows 图形安装器从 WinForms 迁移到 WPF，改为接近 Windows 11”设置”的单页配置界面；
- 新增”跟随系统 / 浅色 / 深色”外观面板；跟随系统时读取 Windows 应用主题，浅色和深色模式均复用系统强调色；
- 增加轻量设置卡片、42 DIP 输入控件和更自然的纵向留白，改善旧版界面过于扁平的问题；
- 外观标题与分段选择器分离，三种主题的选中态统一使用系统强调色；协议名称统一为 VMess，Mihomo 展开按钮改为右侧标准 chevron；
- 左侧集中显示协议、端口、节点认证、SNI、Host 和 WebSocket 路径，Mihomo API、密钥与 Mixed Proxy 默认折叠；
- 右侧使用较弱层级实时显示协议、端口、SNI、Host、路径和校验状态，UUID、密码和 API 密钥只显示”已设置”或”未设置”；
- 窄于 1040 DIP 时自动收起摘要并把空间还给表单；表单独立滚动，底部操作栏始终固定；
- 底部固定”取消”和”验证并安装”，配置不完整时标出并聚焦对应字段；
- 启用 Per-Monitor V2 DPI、ClearType、布局像素对齐和 Segoe UI Variable 字体回退，并复核 100%、125%、150% 和 175% 缩放；
- 深色滚动条使用透明轨道和细深灰滑块，悬停加宽、拖动时使用系统强调色；所有 WPF 窗口共用同一主题模板；
- 已有安装选择、完成/错误提示和文件选择也迁移到 WPF；非交互安装、备份、凭据处理、计划任务和扫描核心逻辑保持不变。

Windows 部署包 SHA-256：

```text
F2D9C2ABD4A44BBDBCE8315EA0A04C76A41C27E004D0B8432FEF4AC40DB1DD0E
```

## [v1.2.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.2.0) — 2026-07-23

- 图形安装器改为”连接与协议 → 节点参数 → 确认安装”三步向导；
- 新增深色步骤导航、分组卡片、就地错误提示和统一的安装结果窗口；
- 确认页显示协议、端口、SNI、Host、WS 路径或模板文件名，UUID、密码和 API 密钥始终脱敏；
- 摘要会隐藏 URL 中意外包含的用户信息，错误详情和安装结果支持复制；
- 改进键盘焦点、可访问名称、Esc/Enter 操作以及高 DPI 和小屏幕滚动；
- 公开 SNI/Host 占位符统一为保留域名 `.example`，安装器拒绝将占位域名写入真实配置；
- 节点生成、凭据处理、事务安装、计划任务和扫描核心逻辑保持不变。

Windows 部署包 SHA-256：

```text
3051903F7F1ACDB1AFFEC942FC3CB0C03A01A5861469D8EAA069D09C3C1BCFF0
```

## [v1.1.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.1.0) — 2026-07-23

- Release 新增可双击的 `Install.cmd` 和 PowerShell 5.1 图形安装向导；
- 内置 VMess、VLESS、Trojan 表单，并支持导入自定义 Mihomo JSON 模板；
- 支持 Cloudflare 标准 HTTPS 端口和显式确认的自定义端口；
- 已有安装默认升级并保留配置，也可事务性重新配置协议与凭据；
- 重新配置时保留原 IP 列表，使用新模板重建 provider 和 Clash YAML；
- 私有配置只进入受控临时目录和本机安装目录，安装结束后清理临时副本；
- 安装前停止正在运行的受管任务，降低升级与扫描并发写入风险；
- 隐私检查新增 Git 已跟踪敏感目录与文件的阻断规则。

Windows 部署包 SHA-256：

```text
6078EB77217123DD7D46DE3014C4F7680B7C669EAD5EFB036687AC01264E4BE4
```

## [v1.0.2](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.2) — 2026-07-23

- 新增候选、TCP、真实代理链路、速度粗测和正式三轮测速的阶段漏斗；
- 分别统计阶段失败、名额未入选、已选未执行和高速组外节点；
- 正式测速全部通过时，在 HTML 报告中显示绿色状态；
- 扫描中途失败时保存部分漏斗并生成可点击报告；
- 兼容旧版决策摘要，不使用缺失字段推导虚假粗测数据。

Windows 部署包 SHA-256：

```text
4AE3B4C860E1A4A3EEA0B85BF104BC7317B188654C21349B6817FBE69065A5B9
```

## [v1.0.1](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.1) — 2026-07-23

- discovery、速度粗测、正式测速和历史 CSV 增加协议与端口；
- 旧版 history CSV 自动迁移表头；
- `last_decision.json` 顶层记录节点协议与端口；
- 保留通知和 HTML 报告中的协议、端口信息。

Windows 部署包 SHA-256：

```text
F39A10202CB8F31E60D7D7EB5887410028002B75634E9EE2B267D851D580E46A
```

## [v1.0.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.0.0) — 2026-07-23

> 此版本已被后续版本取代，仅保留用于历史查阅。

- 首个公开版本；
- 建立标准源码、测试、Windows 脚本和 Release 构建结构；
- 支持可配置协议、端口和自定义 Mihomo 节点模板；
- 提供动态发现、三轮测速、后台任务、通知、健康监控和事务回滚。

Windows 部署包 SHA-256：

```text
C185CA049A1D7A9F77076D6188E190F92E7156BE923C6E7A8439028314969912
```
