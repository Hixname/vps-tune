# mmwx-vps-tune

面向妙妙屋X Agent 节点的 Debian VPS 保守型网络调优包装脚本。

项目自动识别 Debian 版本、内存档位以及妙妙屋X 的 systemd external、systemd embedded 或 Docker host-network 部署，随后调用固定提交并通过 SHA-256 校验的 [`alieismy/debian-vps-tuning`](https://github.com/alieismy/debian-vps-tuning) 上游脚本。

> 上游当前是 `v0.1.0-rc.8` 预发布版。执行前请确保服务商网页控制台或快照可用。脚本不会承诺所有线路都会提高峰值速度。

## 功能

- 自动选择 Debian 12/13、1C1G/1C2G 上游配置；
- 自动识别 `mmw-agent.service` embedded/external Xray；
- 检查 Docker Agent 是否运行并使用 `network_mode: host`；
- 运行时选择 `200 / 500 / 1000 / 自定义` Mbps；
- 超过 1000 Mbps 时，根据实际带宽和目标 RTT 选择 16/32/64 MiB 缓冲；
- 下载上游固定 commit，并用内置 SHA-256 校验；
- 提供 `preflight`、`apply`、`verify`、`status`、`rollback`、`purge`；
- 不升级 Debian、不修改 UFW、不修改妙妙屋X配置、不自动重启 VPS。

## 支持范围

| 项目 | 支持范围 |
|---|---|
| 操作系统 | Debian 12 / Debian 13 |
| 架构 | x86_64 / amd64 |
| 内存 | 768–3072 MiB |
| 妙妙屋X | systemd Agent external/embedded，或 Docker host network |
| 常规带宽 | 100–1000 Mbps |
| 扩展带宽 | 1001–10000 Mbps，但必须满足 64 MiB 缓冲覆盖边界 |
| 队列 | 根 fq、fq_codel、noqueue，或 mq + fq/fq_codel 叶子 |

ARM64、Ubuntu、Alpine、复杂 CAKE/HTB/TBF、策略路由、TProxy、NAT 网关不在支持范围内。

## 项目仓库

安装器默认绑定以下公开仓库：

```text
Hixname/vps-tune
```

仓库地址：[`github.com/Hixname/vps-tune`](https://github.com/Hixname/vps-tune)。如需测试 fork，可临时设置 `MMWX_TUNE_REPO=用户名/仓库名` 覆盖默认地址。

## 一键安装并运行

以下命令需要在 VPS 的 root shell 中执行：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash -s -- apply
```

安装器会：

1. 下载 `mmwx-vps-tune.sh`；
2. 校验内置 SHA-256；
3. 执行 Bash 语法检查；
4. 安装为 `/usr/local/sbin/mmwx-vps-tune`；
5. 运行 `apply`。

运行时显示带宽菜单：

```text
1) 200 Mbps
2) 500 Mbps
3) 1000 Mbps
4) 自定义 100–10000 Mbps
```

预检成功后必须输入大写 `APPLY` 才会修改系统。

### 推荐的可审查安装方式

root 级脚本不应在未检查内容时直接管道执行。更稳妥的方式是先下载和阅读：

```bash
curl -fL -o /root/mmwx-vps-install.sh \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh

less /root/mmwx-vps-install.sh

bash /root/mmwx-vps-install.sh apply
```

## 常用命令

只做预检：

```bash
mmwx-vps-tune preflight
```

应用调优：

```bash
mmwx-vps-tune apply
```

指定带宽而不显示菜单：

```bash
PORT_SPEED_MBPS=1000 mmwx-vps-tune apply
```

重启后验证：

```bash
mmwx-vps-tune verify
```

查看状态：

```bash
mmwx-vps-tune status
```

回滚系统配置并保留脚本创建的应急 swap：

```bash
mmwx-vps-tune rollback
```

回滚并安全清理脚本创建的 swap：

```bash
mmwx-vps-tune purge
```

## 修改已经应用的带宽

上游状态不允许直接用不同参数覆盖。先回滚，再重新选择：

```bash
mmwx-vps-tune rollback
mmwx-vps-tune apply
```

如果现有 swap 是脚本创建且普通回滚显示 `SWAP_RETAINED`，应先执行：

```bash
mmwx-vps-tune purge
mmwx-vps-tune apply
```

外部已有的 `/swapfile` 不会被本项目删除。

## 自定义高带宽逻辑

上游已验证输入范围为 100–1000 Mbps，最大 socket 缓冲为 64 MiB。本包装脚本不会修改上游代码：

- `≤1000 Mbps`：把真实带宽交给上游并使用 `BUF_MAX=auto`；
- `>1000 Mbps`：使用上游 1000 Mbps 兼容输入，并按真实带宽与 RTT 显式选择缓冲；
- 理论 BDP 超过 64 MiB：拒绝执行并显示当前 RTT 下的最大安全带宽。

默认 RTT 为 200 ms，此时 64 MiB 大约覆盖 2684 Mbps。可以显式设置实际目标 RTT：

```bash
PORT_SPEED_MBPS=2000 BUFFER_TARGET_RTT_MS=150 mmwx-vps-tune apply
```

缓冲值是单个 socket 可以增长到的上限，并非启动后立即为每条连接分配全部内存。1 GiB VPS 使用 64 MiB 上限时仍应控制并发，并观察内存和 swap。

## 妙妙屋X适配

根据[妙妙屋X Agent 部署文档](https://miaomiaowux.com/docs/install-agent)：

- `external`：严格验证 `mmw-agent.service` 和 `xray.service`；
- `embedded`：严格验证 `mmw-agent.service`；
- Docker：检查 `mmw-agent` 容器运行状态和 host 网络模式；
- 只有妙妙屋X主控、没有 Agent/Xray 时拒绝应用节点调优。

自定义 Docker 容器名：

```bash
MMWX_CONTAINER=my-agent mmwx-vps-tune verify
```

## sysctl 冲突

预检会拒绝与其他调优文件重复的键，常见提示如下：

```text
sysctl 冲突：net.core.default_qdisc 已在某文件中定义
sysctl 冲突：net.ipv4.tcp_congestion_control 已在某文件中定义
sysctl 冲突：vm.swappiness 已在某文件中定义
```

不要直接删除未知文件。先查看文件内容和归属：

```bash
stat /etc/sysctl.d/文件名
dpkg-query -S /etc/sysctl.d/文件名 2>/dev/null || true
nl -ba /etc/sysctl.d/文件名
```

确认是自己以前创建的调优文件后，先备份到 `/root`，再人工移除重复键。保留备份，以便回滚后恢复原来的持久配置。

## 应用后的变化

具体由固定上游脚本管理，主要包括：

- BBR + fq；
- TCP socket 缓冲上限；
- `somaxconn`、SYN backlog、网卡 backlog；
- TCP Fast Open、MTU probing 和 keepalive；
- `vm.swappiness=20`；
- journald 空间限制；
- 无活动 swap 时可创建受控的应急 swap；
- 原始 qdisc、sysctl 和管理文件状态，用于验证与回滚。

脚本不会改善物理线路绕路、运营商晚高峰拥塞、宿主机 CPU 超售或 Xray 加密瓶颈。Hysteria2 等 UDP/QUIC 协议受到这些 TCP 参数的影响也较少。

## 更新

重新执行安装器即可下载安装仓库中的当前脚本，然后运行指定动作：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash -s -- status
```

修改 `mmwx-vps-tune.sh` 后，必须同步更新：

1. `install.sh` 内的 `EXPECTED_MAIN_SHA256`；
2. 根目录的 `SHA256SUMS`；
3. `CHANGELOG.md`；
4. 版本号。

运行本地检查：

```bash
bash tests/static-check.sh
```

## 安全

- 不要公开妙妙屋X token、VLESS UUID、REALITY 私钥、SSH 私钥或完整配置；
- 不要把未经检查的 fork 直接交给 root shell；
- 运行前保留服务商网页控制台或快照；
- 首次执行建议先运行 `preflight`；
- 参见 [`SECURITY.md`](SECURITY.md)。

## 上游与许可证

- 主机调优逻辑：[alieismy/debian-vps-tuning](https://github.com/alieismy/debian-vps-tuning)
- 妙妙屋X文档：[miaomiaowux.com](https://miaomiaowux.com/)

本包装项目使用 MIT License。上游项目和妙妙屋X分别遵循其自己的许可证和使用条款。
