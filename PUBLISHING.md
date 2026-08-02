# 发布到 GitHub

## 1. 目标仓库

本发布包已经绑定：

```text
https://github.com/Hixname/vps-tune
```

仓库当前如果只有 `vps-tune-github.zip`，需要把压缩包内的文件放到仓库根目录；仅上传 ZIP 无法提供一键安装地址。

## 2. 替换仓库中的 ZIP

在发布包所在目录执行：

```bash
git clone https://github.com/Hixname/vps-tune.git vps-tune
unzip vps-tune-github.zip -d vps-tune-package
cp -R vps-tune-package/vps-tune-github/. vps-tune/
cd vps-tune
```

删除仓库里原来单独上传的 ZIP，然后提交真正的项目文件：

```bash
git rm vps-tune-github.zip
git add .
git commit -m "feat: add mmwx VPS tuning wrapper"
git push origin main
```

完成后，仓库根目录应直接看到 `install.sh`、`mmwx-vps-tune.sh`、`README.md` 和 `.github`，而不是只看到一个 ZIP。不要把 SSH 私钥、妙妙屋X token、Agent 配置或 Xray 私钥复制进仓库。

## 3. 检查 GitHub Actions

进入仓库的 **Actions** 页面，确认 `static-check` 工作流通过。工作流会执行：

- Bash 语法检查；
- ShellCheck；
- 安装器内置主脚本哈希检查；
- `SHA256SUMS` 检查。

## 4. 在 VPS 上使用

root shell：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Hixname/vps-tune/main/install.sh |
  bash -s -- apply
```

更稳妥的审查式安装方法见 [`README.md`](README.md)。

## 5. 创建首个 Release

确认 Actions 通过并完成目标 VPS 验证后再创建版本标签：

```bash
git tag -a v1.1.0 -m "mmwx-vps-tune v1.1.0"
git push origin v1.1.0
```

随后在 GitHub 的 **Releases → Draft a new release** 中选择 `v1.1.0`，附上 ZIP 和 `SHA256SUMS`。正式发布前请至少验证：

1. `preflight`；
2. `apply`；
3. 立即 `verify`；
4. 重启后 `verify`；
5. `rollback`；
6. 原有妙妙屋X节点连通性。
