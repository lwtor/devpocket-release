# DevPocket 安装指南

DevPocket 通过公开 GitHub Release 的版本化 ZIP 分发；源码仓库保持私有。

## Windows

```powershell
irm https://github.com/lwtor/devpocket-release/releases/latest/download/install.ps1 -OutFile devpocket-install.ps1
powershell -ExecutionPolicy Bypass -File .\devpocket-install.ps1
```

安装指定版本：

```powershell
powershell -ExecutionPolicy Bypass -File .\devpocket-install.ps1 -Version '<版本号>'
```

默认安装到 `%LOCALAPPDATA%\DevPocket`，无需管理员权限。新开终端后运行 `devpocket capability`。

## macOS / Linux

```bash
curl -fsSL https://github.com/lwtor/devpocket-release/releases/latest/download/install.sh -o devpocket-install.sh
sh devpocket-install.sh
```

安装指定版本：

```bash
sh devpocket-install.sh --version '<版本号>'
```

默认安装到 `${XDG_DATA_HOME:-$HOME/.local/share}/devpocket`，入口为 `$HOME/.local/bin/devpocket`，不使用 `sudo`。需要自动更新 profile 时增加 `--update-profile`。

## 安全与回滚

安装器读取 `release-manifest.json`，下载不可变的 `devpocket-<version>.zip`，交叉校验 manifest 与 `.sha256`，拒绝 Zip Slip、符号链接及路径越界。升级失败会恢复 `current` 指针和入口，并移除本次未完成版本。

可通过 `-BaseUrl` / `--base-url` 或 `DEVPOCKET_RELEASE_BASE_URL` 切换到镜像、内网或离线 `file://` 地址。