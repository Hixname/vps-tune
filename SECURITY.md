# Security Policy

## 支持范围

首个公开版本仅支持最新的 `1.x` 版本。上游 `debian-vps-tuning` 仍是预发布版本，因此每次更新上游 commit 或 SHA-256 都应重新完成静态检查和目标 VPS 验证。

## 安全报告

请使用 GitHub 仓库的 **Security → Report a vulnerability** 私密报告入口，不要先创建公开 Issue。

报告应包含：

- 包装脚本版本；
- Debian 主版本、内核、架构和内存档位；
- 妙妙屋X部署模式（external、embedded 或 Docker）；
- 执行动作、退出码和脱敏日志；
- 是否涉及 sysctl、qdisc、swap、journald、状态文件或回滚。

不得提交：

- SSH 私钥、密码或 API Token；
- 妙妙屋X Server Token / Agent Token；
- VLESS UUID、REALITY privateKey；
- TLS/ACME 私钥；
- 未脱敏的 Agent 配置或完整 Xray 配置。

## 操作安全

本项目以 root 权限运行。建议先下载、校验和阅读脚本，再执行 `preflight`。使用一键管道命令前，应确认 URL 指向自己控制的 GitHub 仓库和预期分支或 tag。
