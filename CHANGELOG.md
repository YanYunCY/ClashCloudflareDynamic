# 版本历史

全部安装包和 GitHub 自动生成的源码归档见 [Releases 列表](https://github.com/YanYunCY/ClashCloudflareDynamic/releases)。

## [v1.1.0](https://github.com/YanYunCY/ClashCloudflareDynamic/releases/tag/v1.1.0) — 2026-07-23

- Release 新增可双击的 `Install.cmd` 和 PowerShell 5.1 图形安装向导；
- 内置 VMess、VLESS、Trojan 表单，并支持导入自定义 Mihomo JSON 模板；
- 支持 Cloudflare 标准 HTTPS 端口和显式确认的自定义端口；
- 已有安装默认升级并保留配置，也可事务性重新配置协议与凭据；
- 重新配置时保留原 IP 列表，使用新模板重建 provider 和 Clash YAML；
- 私有配置只进入受控临时目录和本机安装目录，安装结束后清理临时副本；
- 安装前停止正在运行的受管任务，降低升级与扫描并发写入风险；
- 隐私检查新增 Git 已跟踪敏感目录与文件的阻断规则。

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
