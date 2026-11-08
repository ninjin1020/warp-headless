# warp-headless

[English](README.md) | 简体中文

适用于 Debian 和 Ubuntu 的 Cloudflare WARP 客户端非官方无图形界面版本。

官方的 `cloudflare-warp` 包把桌面托盘程序（`warp-taskbar`，用 Flutter 写的）和守护进程、命令行工具打在一起，并且依赖 WebKitGTK 和 AppIndicator。在精简安装的 Ubuntu 24.04 上，装官方包会额外装进约 200 个包（GTK、WebKit、GStreamer 等）。本仓库把官方 `.deb` 去掉图形界面后重新打包，装同一个包只需额外装约 10 个。

**保留：** `warp-svc`、`warp-cli`、`warp-diag`、`warp-dex`、`warp-svc.service`，以及维护脚本里设置 capabilities、启用服务、卸载时清理的部分。

**删除：** `warp-taskbar`、`/usr/lib/warp`（Flutter 运行时和插件）、`.desktop` 文件、D-Bus 服务、systemd 用户服务，维护脚本里为每个桌面用户管理托盘程序的代码，以及 `libwebkit2gtk-4.1-0`、`libayatana-appindicator3-1`、`desktop-file-utils` 这三个依赖。

二进制文件本身没有改动。

## 提供的包

GitHub Actions 为以下发行版打包：

| 发行版 | 代号 | 架构 |
|---|---|---|
| Ubuntu 22.04 | jammy | amd64、arm64 |
| Ubuntu 24.04 | noble | amd64、arm64 |
| Debian 12 | bookworm | amd64、arm64 |
| Debian 13 | trixie | amd64、arm64 |

Release 里的文件名格式为 `cloudflare-warp_<版本>-headless1_<代号>_<架构>.deb`，每个 release 都附带 `SHA256SUMS`。

## 安装

从[最新 release](https://github.com/ninjin1020/warp-headless/releases/latest) 下载对应发行版的包，或者通过 GitHub API 下载：

```bash
SUITE=noble ARCH=amd64
url=$(curl -fsSL https://api.github.com/repos/ninjin1020/warp-headless/releases/latest \
  | grep -o "https://[^\"]*_${SUITE}_${ARCH}\.deb" | head -n1)
curl -fLO "$url"
curl -fsSL https://github.com/ninjin1020/warp-headless/releases/latest/download/SHA256SUMS | sha256sum -c --ignore-missing
sudo apt install "./${url##*/}"
```

`warp-cli` 和 `warp-svc` 的用法与官方包完全相同，请参阅 [Cloudflare WARP 客户端文档](https://developers.cloudflare.com/warp-client/)。

### 注意事项

- 包名仍是 `cloudflare-warp`，版本号后加了 `+headless1`。如果同一台机器上配置了 Cloudflare 的 APT 源，上游发布新版本后，`apt upgrade` 会把它换回完整版。要么不添加该源，要么用 `sudo apt-mark hold cloudflare-warp` 锁定版本。
- 升级时安装新 release 里的包即可。
- 安装时上游维护脚本可能会打印一条关于 APT 源公钥的提示，可以忽略。

## 工作原理

[`warp-headless-repack.sh`](warp-headless-repack.sh)：

1. 从 `pkg.cloudflareclient.com` 下载 `InRelease`，用 Cloudflare 公开的密钥校验签名，再按签名内容中的 SHA256 校验 `Packages` 索引和 `.deb`。
2. 解包，删除图形界面相关文件，并检查剩下的二进制文件和符号链接都没有引用被删除的内容。
3. 从 `postinst`、`prerm`、`postrm` 中删除只服务于桌面环境的函数及调用它们的行，然后检查脚本语法，有图形界面相关代码残留就报错。
4. 去掉只有图形界面需要的依赖，更新版本号、`Installed-Size`、`Maintainer` 和描述，重新生成 `md5sums`，最后重新打包。

上游包结构出现意外变化时，脚本会报错退出，不会产出有问题的包。

## 自动构建

[`.github/workflows/build.yml`](.github/workflows/build.yml)：

- 每天检查一次 Cloudflare 的软件源。有新版本时，为所有发行版和架构打包，并发布标签为 `v<上游版本>` 的 release。
- 修改构建相关文件并推送到 `main`、或者手动运行时也会构建；手动运行时勾选 `force` 会重建当前版本。
- 每个包都会在对应发行版的干净容器里实际安装一遍（arm64 通过 QEMU 运行）。只要装进了图形界面相关的包、有动态库找不到、`warp-cli` 无法运行、或 `warp-svc` 的 capabilities 没设好，检查就会失败。详见 [`ci/smoke-test.sh`](ci/smoke-test.sh)。

要调整发行版或架构，修改 workflow 开头的 `SUITES` 和 `ARCHES`。

## 本地打包

在装有 `dpkg-deb`、`curl`、`gpg`、`gpgv` 的 Debian 系系统上运行，不需要 root：

```bash
./warp-headless-repack.sh                          # 当前系统对应的最新版
SUITE=jammy ARCH=arm64 ./warp-headless-repack.sh   # 指定发行版和架构
./warp-headless-repack.sh cloudflare-warp_X.deb    # 使用已有的 .deb
```

环境变量：`SUITE`、`ARCH`、`OUT_DIR`、`SUFFIX`（默认 `+headless1`）、`MAINTAINER`。

## 免责声明

本项目与 Cloudflare, Inc. 无关，未获其认可或支持。"Cloudflare" 和 "WARP" 是 Cloudflare, Inc. 的商标。

WARP 客户端是 Cloudflare 按其自有条款分发的专有软件，详见 [Cloudflare 应用服务条款](https://www.cloudflare.com/application/terms/)。Release 中的文件包含 Cloudflare 原样未改的二进制文件，只是重新打包。本仓库的 MIT 许可证只适用于仓库里的脚本和 workflow 文件，不适用于 Cloudflare 的软件。

使用风险自负。打包相关的问题请在本仓库提 issue，请不要就这些包联系 Cloudflare 支持。

## 许可证

[MIT](LICENSE)
