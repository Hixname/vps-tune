# 发布 v2 到 GitHub

目标仓库：[`Hixname/vps-tune`](https://github.com/Hixname/vps-tune)。

## 1. 进入本地仓库

```bash
cd "/Users/me/Documents/Codex/2026-08-03/alieismy-debian-vps-tuning-https-github/outputs/vps-tune"
```

## 2. 检查改动

```bash
git status --short
git diff --check
```

确认没有 SSH 私钥、妙妙屋X token、Agent 配置、Xray 私钥或其他秘密。

## 3. 运行发布检查

```bash
bash tests/static-check.sh
```

必须看到所有脚本 `OK`、公式测试通过和最终的“静态检查通过”。

## 4. 提交 v2

```bash
git add .github/workflows/ci.yml CHANGELOG.md PUBLISHING.md README.md SECURITY.md \
  SHA256SUMS install.sh mmwx-vps-tune.sh tests/formula-test.sh tests/static-check.sh

git commit -m "feat: add v2 interactive tuning workflow"
```

## 5. 推送 main

```bash
git push origin main
```

## 6. 检查 GitHub Actions

```bash
gh run list --repo Hixname/vps-tune --limit 3
```

打开最新运行并确认 `static-check` 成功。工作流包括 Bash 语法、ShellCheck、安装器主脚本哈希、项目 SHA-256、三档公式和安全边界测试。

## 7. 从 GitHub 公网预检

先在测试 VPS 下载并打开菜单：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash
```

正式发布前至少完成：

1. 全新安装；
2. 三档公式摘要检查；
3. 带宽和自定义 RTT；
4. 带软链接的 sysctl 冲突迁移；
5. 立即生效检测；
6. 重启后生效检测；
7. 覆盖重新安装；
8. 恢复原始状态；
9. 确认原 sysctl 文件哈希与内容恢复；
10. 确认妙妙屋X节点全程可用。

## 8. 创建 v2.0.0 标签

只有 Actions 和目标 VPS 测试全部通过后才执行：

```bash
git tag -a v2.0.0 -m "vps-tune v2.0.0"
git push origin v2.0.0
```

## 9. 创建 GitHub Release

在 GitHub 的 **Releases → Draft a new release** 中选择 `v2.0.0`，附上：

```text
vps-tune-github.zip
vps-tune-github.zip.sha256
```

Release 说明应明确：上游仍为 `v0.1.0-rc.8`，极限档位不适合作为 1 GiB VPS 的默认选择，首次公开使用前应保留服务商控制台或快照。
