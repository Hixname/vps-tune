# vps-tune

面向妙妙屋X Agent/Xray 节点的 Debian VPS 网络调优菜单脚本，支持预检、安全安装、覆盖重装、状态检查、生效验证和恢复原始状态。

当前版本：`v2.1.0`。项目仓库：[`Hixname/vps-tune`](https://github.com/Hixname/vps-tune)。

底层主机调优固定使用已审阅提交的 [`alieismy/debian-vps-tuning`](https://github.com/alieismy/debian-vps-tuning)，并对下载文件执行 SHA-256 校验。上游仍是 `v0.1.0-rc.8` 预发布版，运行前必须保证服务商网页控制台或快照可用。

## 1. 一键安装

先进入 `root`：

```bash
sudo -i
```

然后执行 GitHub 一键安装并打开菜单：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash
```

安装器会：

1. 从 `Hixname/vps-tune` 下载主脚本；
2. 校验主脚本 SHA-256；
3. 执行 Bash 语法检查；
4. 安装为 `/usr/local/sbin/mmwx-vps-tune`；
5. 打开编号主菜单。

以后直接执行：

```bash
mmwx-vps-tune
```

## 2. 功能概览

- 全新安装时选择保守、激进或极限调优；
- 带宽支持 `200 / 500 / 1000 / 自定义` Mbps；
- RTT 支持 `50 / 100 / 150 / 200 / 300 / 自定义` ms；
- 可直接输入 `175ms`、`175 ms`、`1000M` 或 `1000Mbps`；
- 安全处理服务商镜像已存在的 BBR/fq/sysctl 重复定义；
- 支持覆盖重装和带哈希保护的完整恢复；
- 生效检测会检查 BBR、fq、socket 缓冲、CPU、内存、swap、网卡错误、qdisc 丢包、NOFILE 和妙妙屋X/Xray 服务；
- 不升级 Debian、不修改 UFW、不修改妙妙屋X节点配置、不自动重启 VPS。

## 3. 支持范围

| 项目 | 支持范围 |
|---|---|
| 操作系统 | Debian 12 / Debian 13 |
| 架构 | x86_64 / amd64 |
| 内存 | 768–3072 MiB |
| 调优档案 | 上游 1C1G / 1C2G 档案，按实际内存自动选择 |
| 妙妙屋X | systemd embedded/external、Docker host network，或独立 Xray |
| 输入带宽 | 100–10000 Mbps，仍需通过 64 MiB 安全边界 |
| 目标 RTT | 20–500 ms |
| 队列 | fq、fq_codel、noqueue，或 mq + fq/fq_codel 叶子 |

不支持：ARM64、Ubuntu、Alpine、复杂 CAKE/HTB/TBF、TProxy、策略路由、NAT 网关或只有妙妙屋X主控而没有 Agent/Xray 的机器。

## 4. 三种调优档位怎么选

三档只改变经过验证的 TCP socket 缓冲余量。BBR、fq、backlog、Fast Open、keepalive、journald 和事务恢复基线保持一致。

| 档位 | 菜单说明 | BDP 余量 | 最低缓冲 | 建议用途 |
|---|---|---:|---:|---|
| 保守调优 | 适用于 1H1G/1H2G 日常节点 | 1.0× | 8 MiB | 默认推荐；200–1000Mbps、妙妙屋X/Xray、小到中等并发 |
| 激进调优 | 适用于至少 2G 内存、高 RTT/高波动千兆线路 | 1.5× | 16 MiB | 已证明保守档窗口余量不足，且可用内存充足 |
| 极限调优 | 仅适用于至少 2G 内存的专项测试 | 2.0× | 32 MiB | 高带宽/高 RTT 专项实验；高内存压力，需持续监控 |

重要：

- 更高档位不会修复物理线路丢包、晚高峰拥堵、路由绕行或单核 CPU 瓶颈；
- 当保守档已覆盖理论 BDP，继续增大缓冲通常不会让测速直接提高；
- 这些数值是单个 socket 可以增长到的上限，不是启动时为每条连接立即分配的内存；
- 1H1G 不确定时始终选择保守档。

### 4.1 实际计算示例

| 带宽 / RTT | 保守 | 激进 | 极限 |
|---|---:|---:|---:|
| 200Mbps / 175ms | 8 MiB | 16 MiB | 32 MiB |
| 1000Mbps / 175ms | 21 MiB | 32 MiB | 42 MiB |
| 1000Mbps / 200ms | 24 MiB | 36 MiB | 48 MiB |

## 5. 带宽和 RTT 应该怎么填

### 5.1 带宽

填写 VPS 套餐标注的端口带宽，不要把某次测速的瞬时峰值当成套餐带宽。某些线路、IPv6 或测速节点可能出现超过套餐标称的突发值。

互动菜单接受：

```text
1000
1000M
1000Mbps
1000 Mbps
```

### 5.2 RTT

RTT 应以主要用户到 VPS 实际入口端口的 TCP 延迟为准。ITDog 可作为参考，优先看与用户同地区、同运营商的节点，取晚高峰平均值或稍高一点的约 75% 分位值。

不要使用：

- 全国最低延迟；
- 偶发的 400–500ms 尖峰；
- VPS 访问本地 CDN 的 1–5ms 延迟。

互动菜单接受：

```text
175
175ms
175 ms
```

中国到美国等跨境线路不确定时，可先选择 `200ms`。

## 6. 全新安装：严格按顺序执行

### 6.1 准备恢复入口

1. 打开并确认服务商网页控制台可用；
2. 有快照功能时先创建快照；
3. 保留当前 SSH 会话；
4. 准备第二个 SSH 窗口用于应用后测试。

### 6.2 打开菜单

```bash
mmwx-vps-tune
```

主菜单：

```text
1. 全新安装（保守 / 激进 / 极限）
2. 覆盖重新安装
3. 当前优化状态
4. 恢复到原始状态
5. 生效检测
0. 退出
```

全新 VPS 选择 `1`。

### 6.3 选择档位

```text
1) 保守调优（推荐；适用于 1H1G/1H2G 日常节点）
2) 激进调优（适用于至少 2G 内存、高 RTT/高波动千兆线路）
3) 极限调优（仅适用于至少 2G 内存的专项测试）
```

1H1G 机器选择 `1`。

### 6.4 选择带宽和 RTT

可以选择菜单编号，也可直接输入数值。例如 1H1G、1000Mbps、平均 RTT 175ms：

```text
档位：1
带宽：1000Mbps
RTT：175ms
```

### 6.5 处理 sysctl 冲突

如果服务商镜像已经定义 BBR/fq 等键，脚本会：

1. 使用真实路径和设备/inode 去重，避免 `/etc/sysctl.d/99-sysctl.conf -> ../sysctl.conf` 被重复报告；
2. 完整备份每个原文件；
3. 只移除本项目要接管的重复键；
4. 保存原始哈希和迁移后哈希；
5. 在恢复菜单中还原。

确认报告文件后输入：

```text
MIGRATE
```

备份目录：

```text
/var/lib/mmwx-vps-tune/sysctl-originals
```

如果迁移后的文件被其他程序修改，恢复操作会拒绝盲目覆盖并保留备份。

### 6.6 应用配置

保守或激进档输入：

```text
APPLY
```

极限档输入：

```text
EXTREME
```

### 6.7 测试 SSH 和妙妙屋X

1. 不要关闭当前 SSH；
2. 打开第二个 SSH 窗口并确认能登录；
3. 确认妙妙屋X节点仍在线；
4. 确认后手动重启：

```bash
reboot
```

### 6.8 重启后生效检测

```bash
mmwx-vps-tune verify
```

也可以打开菜单并选择 `5`。

## 7. 覆盖重新安装

适用于：

- 修改带宽、RTT 或调优档位；
- 升级到新版脚本后重新应用；
- 上次已存在受管调优状态。

执行顺序：

1. 运行 `mmwx-vps-tune`；
2. 选择 `2. 覆盖重新安装`；
3. 重新选择档位、带宽和 RTT；
4. 检查 BDP、缓冲和硬件摘要；
5. 输入 `REINSTALL`；
6. 脚本先通过上游事务回滚旧状态；
7. 按提示输入 `APPLY` 或 `EXTREME`；
8. 新开 SSH 测试，再重启并执行 `verify`。

已经安装的机器不要反复选择“全新安装”。

## 8. 当前状态和生效检测

当前状态：

```bash
mmwx-vps-tune status
```

严格生效检测：

```bash
mmwx-vps-tune verify
```

`verify` 包含：

- 受管文件和状态哈希；
- BBR、fq 和所有受管 sysctl；
- swap 所有权和持久化；
- 妙妙屋X/Xray 服务；
- 实际 `rmem_max/wmem_max` 能否覆盖目标 BDP；
- CPU、可用内存和 swap 用量；
- 默认出口网卡、qdisc 累计丢包、网卡丢包和错误计数；
- 运行中服务 NOFILE。

### 8.1 诊断输出怎么看

```text
[+] 实际 socket 缓冲已覆盖目标 BDP
```

表示不需要为了测速盲目换到更高档位。

```text
[!] 1 核千兆节点可能遇到 CPU 瓶颈
```

表示应该在真实 Xray 测速时另开 SSH 运行：

```bash
top
```

如果 `xray` 或 `mmw-agent` 长时间接近单核 100%，下一步应升级 CPU，而不是继续放大 TCP 缓冲。

`qdisc_drop` 和网卡统计是开机以来的累计值，单次非零不等于当前正在丢包；应在测速前后对比增量。

### 8.2 NOFILE=65535

上游脚本以 `65536` 为提示阈值，部分妙妙屋X服务运行值是 `65535`。v2.1.0 会明确标记 `65535` 为可接受，不会为相差 1 而自动改写 systemd 服务。

## 9. 恢复到原始状态

```bash
mmwx-vps-tune restore
```

输入：

```text
RESTORE
```

脚本会：

1. 恢复原始 qdisc 和 sysctl；
2. 移除本项目管理的文件；
3. 清理由脚本创建的 swap；
4. 恢复 v2 自动迁移的 sysctl 原文件；
5. 验证备份哈希，拒绝覆盖安装后被其他程序修改的文件。

外部原本已经存在的 `/swapfile` 不属于本项目，不会被删除。不要手工删除 `/var/lib/proxy-vps-tuning` 或 `/var/lib/mmwx-vps-tune` 来代替恢复菜单。

## 10. 非交互使用

示例：

```bash
TUNING_MODE=conservative \
PORT_SPEED_MBPS=1000Mbps \
BUFFER_TARGET_RTT_MS='175 ms' \
mmwx-vps-tune install
```

完整变量：

```text
TUNING_MODE=conservative|aggressive|extreme
PORT_SPEED_MBPS=100..10000，或 1000M/1000Mbps
BUFFER_TARGET_RTT_MS=20..500，或 175ms/175 ms
ENABLE_SWAP=0|1
SWAP_MB=512..4096
AUTO_APPLY=0|1
AUTO_MIGRATE_SYSCTL=0|1
INSTALL_DEPS=0|1
MMWX_CONTAINER=容器名
```

`AUTO_APPLY=1` 和 `AUTO_MIGRATE_SYSCTL=1` 会跳过人工确认，只适合已经审查日志、具备快照和服务商控制台的自动化环境。

## 11. 高带宽边界

上游带宽输入上限是 1000Mbps。对于超过 1000Mbps 的端口，包装脚本使用上游 1000Mbps 兼容输入，但仍然根据真实带宽、RTT 和档位计算显式缓冲。

任何组合一旦需要超过 64MiB，脚本会拒绝执行并给出当前档位的最大安全带宽。小内存 VPS 应优先降低档位或按真实用户线路修正 RTT，不应盲目继续增大上限。

## 12. 怎么解读 TcpQuality 等测速报告

- 先确认 `bbr`、`fq`、TCP 窗口缩放和接收自调正常；
- 200Mbps/175–200ms 保守档显示 8MiB 是正常结果；
- 1000Mbps/175ms 保守档显示 21MiB 是正常结果；
- 回程速度因运营商和路由差异很大，不能仅凭一次报告改变内核档位；
- 局部节点大包重传而其他几十个节点正常，应先在平峰和晚高峰重复测试；
- 外部测速不能测出 Xray 加密的真实 CPU 开销；
- 脚本无法解决路由绕行、运营商拥堵、宿主机超售或服务商限速。

## 13. 妙妙屋X部署适配

- systemd embedded：验证 `mmw-agent.service`；
- systemd external：验证 `mmw-agent.service` 和 `xray.service`；
- Docker：要求 Agent 容器运行并使用 host network；
- 独立 Xray：可以使用，但会显示兼容提示；
- 只有妙妙屋X主控，没有 Agent/Xray：拒绝应用节点调优。

自定义 Docker 容器名：

```bash
MMWX_CONTAINER=my-agent mmwx-vps-tune verify
```

## 14. 安全说明

- 不要公开 SSH 私钥、妙妙屋X token、VLESS UUID 或 REALITY 私钥；
- 首次使用前保留服务商控制台或快照；
- 应用后先新开 SSH 测试，再手动重启；
- 不要在有复杂队列、TProxy、策略路由或 NAT 网关的主机上强行使用；
- Hysteria2 等 UDP/QUIC 协议受这些 TCP 参数影响较少。

更多信息见 [`SECURITY.md`](SECURITY.md)。

## 15. 开发和发布检查

修改主脚本后必须同步更新 `install.sh` 中的主脚本 SHA-256 和 `SHA256SUMS`，然后执行：

```bash
bash tests/static-check.sh
```

检查包含：

- Bash 语法；
- ShellCheck；
- 安装器内置主脚本哈希；
- 项目 SHA-256；
- 200/1000Mbps 和 175/200ms 公式；
- `175ms`、`175 ms`、`1000M`、`1000Mbps` 输入容错；
- 三档计算和 64MiB 边界；
- sysctl 受管键匹配。

完整发布步骤见 [`PUBLISHING.md`](PUBLISHING.md)。

## 16. 许可证

本包装项目使用 MIT License。上游项目和妙妙屋X分别遵循各自的许可证和使用条款。
