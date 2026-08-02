# vps-tune

面向妙妙屋X Agent 节点的 Debian VPS 可验证、可覆盖重装、可恢复的网络调优菜单脚本。

当前版本：`v2.0.0`。项目仓库：[`Hixname/vps-tune`](https://github.com/Hixname/vps-tune)。

主机调优事务继续使用固定提交并通过 SHA-256 校验的 [`alieismy/debian-vps-tuning`](https://github.com/alieismy/debian-vps-tuning)。上游仍是 `v0.1.0-rc.8` 预发布版，因此运行前必须保证服务商网页控制台或快照可用。

## 1. 功能

- 统一编号主菜单；
- 全新安装时选择保守、激进或极限调优；
- 带宽选择 `200 / 500 / 1000 / 自定义` Mbps；
- RTT 选择 `50 / 100 / 150 / 200 / 300 / 自定义` ms；
- 安全覆盖重新安装；
- 当前状态、恢复原始状态、生效检测；
- 自动识别 Debian 12/13、1C1G/1C2G 和妙妙屋X部署方式；
- 固定上游 commit，并校验四个上游脚本的 SHA-256；
- sysctl 冲突按真实路径去重，避免软链接重复报告；
- 经确认后备份并迁移冲突键，恢复时进行哈希保护；
- 不升级 Debian、不修改 UFW、不修改妙妙屋X配置、不自动重启。

## 2. 支持范围

| 项目 | 支持范围 |
|---|---|
| 操作系统 | Debian 12 / Debian 13 |
| 架构 | x86_64 / amd64 |
| 内存 | 768–3072 MiB |
| 妙妙屋X | systemd embedded/external，Docker host network，或独立 Xray |
| 输入带宽 | 100–10000 Mbps，仍需通过 64 MiB 缓冲边界检查 |
| 目标 RTT | 20–500 ms |
| 队列 | fq、fq_codel、noqueue，或 mq + fq/fq_codel 叶子 |

ARM64、Ubuntu、Alpine、复杂 CAKE/HTB/TBF、TProxy、策略路由和 NAT 网关不在支持范围内。

## 3. 三种调优档位

三档只改变经过验证的 socket 缓冲余量。BBR、fq、backlog、Fast Open、keepalive、journald 和事务回滚基线保持一致，避免加入无法证明有效的“万能 sysctl”。

| 档位 | BDP 余量 | 最低缓冲 | 适用情况 |
|---|---:|---:|---|
| 保守调优 | 1.0× | 8 MiB | 推荐默认；1 GiB、小并发、重视内存稳定性 |
| 激进调优 | 1.5× | 16 MiB | 高并发、跨境线路、有一定内存余量 |
| 极限调优 | 2.0× | 32 MiB | 明确了解内存风险并持续监控的场景 |

以 `1000 Mbps / 200 ms` 为例：

| 档位 | 计算后的 socket 上限 |
|---|---:|
| 保守 | 24 MiB |
| 激进 | 36 MiB |
| 极限 | 48 MiB |

这些数值是单个 socket 可以增长到的上限，不是启动时为每条连接立即分配的内存。极限调优需要输入 `EXTREME` 确认。

## 4. 全新安装：严格按编号执行

### 4.1 保留恢复入口

1. 打开并确认服务商网页控制台可用。
2. 有快照功能时先创建快照。
3. 保留当前 SSH 会话，应用后用第二个 SSH 会话测试。

### 4.2 进入 root

```bash
sudo -i
```

已经是 `root@主机名` 时跳过此步。

### 4.3 一键下载并打开菜单

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash
```

安装器会校验主脚本 SHA-256，安装为：

```text
/usr/local/sbin/mmwx-vps-tune
```

### 4.4 主菜单选择 `1`

```text
1. 全新安装（保守 / 激进 / 极限）
2. 覆盖重新安装
3. 当前优化状态
4. 恢复到原始状态
5. 生效检测
0. 退出
```

### 4.5 选择调优档位

```text
1) 保守调优（推荐）
2) 激进调优
3) 极限调优
```

不确定时选择 `1`。

### 4.6 选择带宽

```text
1) 200 Mbps
2) 500 Mbps
3) 1000 Mbps
4) 自定义 100–10000 Mbps
```

按 VPS 套餐的端口带宽选择，不要填写测速软件偶然测得的峰值。

### 4.7 选择目标 RTT

```text
1) 50 ms
2) 100 ms
3) 150 ms
4) 200 ms
5) 300 ms
6) 自定义 20–500 ms
```

目标 RTT 是希望高速传输可以覆盖的主要线路往返时延。中国到美国等跨境线路不确定时可先使用 `200 ms`；同地区低延迟线路应选择更接近实际值的选项。

### 4.8 处理 sysctl 冲突

如果服务商镜像已经包含 BBR/fq 等配置，脚本会：

1. 使用 `readlink -f` 按真实文件去重；
2. 完整备份每个原文件；
3. 只移除本项目即将接管的重复键；
4. 保存迁移后哈希；
5. 在恢复菜单中还原原文件。

确认报告中的文件后输入：

```text
MIGRATE
```

备份位于：

```text
/var/lib/mmwx-vps-tune/sysctl-originals
```

如果迁移后的文件又被其他程序修改，恢复操作会拒绝覆盖，并保留备份供人工处理。

### 4.9 应用配置

保守或激进档位输入：

```text
APPLY
```

极限档位输入：

```text
EXTREME
```

### 4.10 测试 SSH 并重启

1. 不要关闭当前 SSH。
2. 新开第二个 SSH 窗口确认可以登录。
3. 确认妙妙屋X节点正常在线。
4. 手动重启：

```bash
reboot
```

### 4.11 重启后生效检测

```bash
mmwx-vps-tune verify
```

也可以重新打开菜单并选择 `5`。

## 5. 覆盖重新安装：严格按编号执行

适用于修改带宽、RTT、调优档位，或者从 v1 升级到 v2。

1. 打开菜单：

```bash
mmwx-vps-tune
```

2. 选择 `2. 覆盖重新安装`。
3. 重新选择档位、带宽和 RTT。
4. 检查摘要。
5. 输入：

```text
REINSTALL
```

6. 脚本先通过上游事务回滚并清理脚本创建的 swap。
7. 原始 sysctl 迁移备份继续保留，不做无意义的恢复再删除。
8. 按提示输入 `APPLY` 或 `EXTREME`。
9. 新开 SSH 测试，随后手动重启并执行 `verify`。

不要在参数变化时直接重复执行全新安装；应使用覆盖重新安装。

## 6. 当前优化状态

菜单选择 `3`，或者执行：

```bash
mmwx-vps-tune status
```

输出包括上游事务状态、带宽、RTT、缓冲、BBR、qdisc、swap、监听端口和服务状态。

## 7. 恢复到原始状态

1. 打开菜单并选择 `4`，或者执行：

```bash
mmwx-vps-tune restore
```

2. 输入：

```text
RESTORE
```

3. 脚本恢复原始 qdisc 和 sysctl，移除管理文件，清理脚本创建的 swap，并恢复 v2 自动迁移的 sysctl 原文件。
4. 如果文件在安装后被外部修改，脚本会拒绝覆盖并保留证据；此时不要手工删除状态目录。

外部原本已经存在的 `/swapfile` 不属于本项目，不会被删除。

## 8. 生效检测

菜单选择 `5`，或者执行：

```bash
mmwx-vps-tune verify
```

验证内容包括管理文件哈希、sysctl、qdisc、swap 所有权，以及妙妙屋X/Xray服务。

## 9. 非交互参数

明确理解风险后，可通过环境变量指定：

```bash
TUNING_MODE=conservative \
PORT_SPEED_MBPS=1000 \
BUFFER_TARGET_RTT_MS=200 \
mmwx-vps-tune install
```

完整变量：

```text
TUNING_MODE=conservative|aggressive|extreme
PORT_SPEED_MBPS=100..10000
BUFFER_TARGET_RTT_MS=20..500
ENABLE_SWAP=0|1
SWAP_MB=512..4096
AUTO_APPLY=0|1
AUTO_MIGRATE_SYSCTL=0|1
INSTALL_DEPS=0|1
MMWX_CONTAINER=容器名
```

`AUTO_APPLY=1` 和 `AUTO_MIGRATE_SYSCTL=1` 会跳过人工确认，只适合已经审查日志、具备快照和控制台的自动化环境。

## 10. 高带宽边界

上游输入上限是 1000 Mbps。对于超过 1000 Mbps 的真实端口，包装脚本使用上游 1000 Mbps 兼容输入，但仍根据真实带宽、RTT 和档位计算显式缓冲。

任何组合一旦需要超过 64 MiB，脚本会拒绝执行，并给出当前档位的最大安全带宽。降低 RTT 或调优档位通常比盲目继续增大缓冲更适合小内存 VPS。

## 11. 妙妙屋X适配

- systemd embedded：验证 `mmw-agent.service`；
- systemd external：验证 `mmw-agent.service` 和 `xray.service`；
- Docker：要求 Agent 容器运行并使用 host network；
- 只有妙妙屋X主控、没有 Agent/Xray：拒绝应用节点调优。

自定义 Docker 容器名：

```bash
MMWX_CONTAINER=my-agent mmwx-vps-tune verify
```

## 12. 安全与限制

- 不要公开 SSH 私钥、妙妙屋X token、VLESS UUID 或 REALITY 私钥；
- 不要删除 `/var/lib/proxy-vps-tuning` 或 `/var/lib/mmwx-vps-tune` 来代替恢复菜单；
- 上游仍是预发布版，正式使用前应在同规格测试机完成安装、重启、验证和恢复演练；
- 脚本不能解决物理线路绕路、运营商晚高峰拥塞、宿主机超售或 Xray 加密性能瓶颈；
- Hysteria2 等 UDP/QUIC 协议受这些 TCP 参数的影响较少。

更多安全说明见 [`SECURITY.md`](SECURITY.md)，发布步骤见 [`PUBLISHING.md`](PUBLISHING.md)。

## 13. 开发检查

修改主脚本后必须同步更新安装器哈希和 `SHA256SUMS`，然后执行：

```bash
bash tests/static-check.sh
```

检查包括 Bash 语法、ShellCheck、主脚本哈希、项目 SHA-256、三档计算、64 MiB 边界和 sysctl 匹配正则。

## 14. 许可证

本包装项目使用 MIT License。上游项目和妙妙屋X分别遵循其自己的许可证和使用条款。
