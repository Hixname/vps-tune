# Security Policy

## 支持范围

项目仅支持最新的 `2.x` 版本。上游 `debian-vps-tuning` 仍是预发布版本，因此每次更新上游 commit、调优公式或 SHA-256 都应重新完成静态检查和目标 VPS 验证。

## 安全报告

请使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告入口，不要先创建公开 Issue。

报告应包含：

- 包装脚本版本；
- Debian 主版本、内核、架构和内存档位；
- 妙妙屋X部署模式（external、embedded 或 Docker）；
- 执行动作、退出码和脱敏日志；
- 是否涉及 sysctl、qdisc、swap、journald、状态文件或回滚。
- 是否存在 `/var/lib/mmwx-vps-tune/sysctl-migrations.tsv`，以及原文件是否在迁移后被其他程序修改。

不得提交：

- SSH 私钥、密码或 API Token；
- 妙妙屋X Server Token / Agent Token；
- VLESS UUID、REALITY privateKey；
- TLS/ACME 私钥；
- 未脱敏的 Agent 配置或完整 Xray 配置。

## 操作安全

本项目以 root 权限运行。建议先下载、校验和阅读脚本，再执行 `preflight`。使用一键管道命令前，应确认 URL 指向自己控制的 GitHub 仓库和预期分支或 tag。

sysctl 自动迁移默认需要输入 `MIGRATE`。脚本只迁移固定上游实际管理的键，按真实文件路径去重，保留完整备份并记录迁移后哈希。恢复时如果原路径、备份哈希或迁移后哈希不匹配，脚本必须拒绝覆盖。

不要手工删除以下状态目录来代替恢复菜单：

```text
/var/lib/proxy-vps-tuning
/var/lib/mmwx-vps-tune
```
