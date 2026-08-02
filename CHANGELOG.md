# Changelog

本项目采用 Semantic Versioning。

## [1.1.0] - 2026-08-03

### Added

- 运行时带宽菜单：200、500、1000 Mbps 和自定义；
- 1001–10000 Mbps 扩展输入；
- 基于真实带宽与目标 RTT 的 16/32/64 MiB 缓冲选择；
- 超过 64 MiB 理论 BDP 时安全拒绝；
- GitHub 一键安装器、中文 README、安全说明和静态检查。
- 安装器默认绑定公开仓库 `Hixname/vps-tune`，仍允许环境变量覆盖以测试 fork。

### Safety

- 固定上游 `debian-vps-tuning` commit；
- 对四个上游资源脚本使用内置 SHA-256；
- 高于 1000 Mbps 时不修改上游代码，而是使用其兼容输入和显式缓冲；
- 不自动修改 UFW，不自动重启 VPS。

### Fixed

- 将范围检查改为明确的条件分支，兼容 GitHub Actions 使用的 ShellCheck，运行逻辑不变。

## [1.0.0] - 2026-08-03

### Added

- 自动识别 Debian 12/13 和 1C1G/1C2G 档位；
- 识别妙妙屋X systemd external/embedded 和 Docker host-network；
- 自动安装最小依赖；
- 上游下载与 SHA-256 校验；
- 预检、应用、验证、状态和回滚包装流程。
