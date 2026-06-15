# qb-installer

一个**只装 qBittorrent** 的独立安装脚本，支持**交互**和**带参数**两种模式。

与完整的 [Dedicated-Seedbox](https://github.com/SAGIRIxr/Dedicated-Seedbox) 安装器不同，本脚本：

- **只**安装 `qbittorrent-nox` 及其 WebUI；
- **不**修改 `sysctl` / 内核参数；
- **不**安装 BBR；
- **不**安装任何其它组件（autobrr、vertex、filebrowser 等）。


## 使用方法

在 Debian/Ubuntu 上以 **root** 运行。

### 1. 交互模式（不带参数）

```bash
bash <(wget -qO- https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh)
```

> 国内服务器若连不上 GitHub，可用代理拉取脚本本身（脚本内部的下载会再默认走 `https://ghfast.top/`）：
>
> ```bash
> bash <(wget -qO- https://ghfast.top/https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh)
> ```

脚本会：

1. 检测 CPU 架构（x86_64 / ARM64）；
2. 列出该架构下**真实存在**的 qBittorrent 构建（含 libtorrent 配对及 `x64_v3` 之类的 CPU 优化版）让你选；
3. 依次询问 **用户名**、**密码**、**磁盘缓存（MiB）**、**下载路径**、**WebUI 端口**、**入站/BT 端口**；
4. 创建用户、下载二进制、写入 `qBittorrent.conf`、安装 `qbittorrent-nox@<用户>.service` 服务并启动。

### 2. 带参数模式（可无人值守）

任何参数都可以单独给：**给了就跳过对应的提问，没给的仍然会交互询问**。
全部给齐并加 `-y`，即可全自动安装。

```bash
bash <(wget -qO- https://raw.githubusercontent.com/SAGIRIxr/qb-installer/main/install.sh) \
  -u alice -p 's3cret' -c 2048 -q 5.0.5 -l v1.2.20 -s x64_v3 -y
```

| 参数 | 含义 | 默认值 |
|------|------|--------|
| `-u <用户名>` | WebUI 用户名 | 必填 |
| `-p <密码>` | WebUI 密码 | 必填 |
| `-c <MiB>` | 磁盘缓存大小（MiB，如 2048） | 必填 |
| `-d <路径>` | 下载路径 | `/home/<用户>/qbittorrent/Downloads` |
| `-q <版本>` | qBittorrent 版本（如 `5.0.5`） | 交互选择 |
| `-l <版本>` | libtorrent 版本（如 `v1.2.20` 或 `1_1_14`） | 交互选择 |
| `-s <后缀>` | 构建后缀 / CPU 优化（如 `x64_v3`），没有就不填 | 无 |
| `-w <端口>` | WebUI 端口 | `8080` |
| `-i <端口>` | 入站 / BT 端口 | `45000` |
| `-g <代理>` | GitHub 加速代理，用于拉取所有 GitHub 文件；传 `-g ""` 直连 | `https://ghfast.top/` |
| `-y` | 跳过最后的确认提示 | — |
| `-h` | 显示帮助并退出 | — |

> 说明：构建由 `-q`、`-l`（及可选的 `-s`）拼成，必须匹配 `Seedbox-Components-P` 里真实存在的目录。
> 若指定的组合不存在，交互模式会改为弹出菜单让你选；无人值守模式则报错并列出全部可用构建。

安装完成后会打印 WebUI 地址和服务管理命令。

## 管理服务

```bash
systemctl status  qbittorrent-nox@<用户>
systemctl restart qbittorrent-nox@<用户>
systemctl stop    qbittorrent-nox@<用户>
journalctl -u qbittorrent-nox@<用户> --no-pager -n 50
```

## 备注

- 脚本只写 qBittorrent 自身的配置（缓存、IO 缓冲、保存路径、WebUI 账号密码），不改动任何系统级设置。
- 配置格式按所选 qBittorrent 版本自动判断（4.1.x 用 MD5 哈希，4.2+ 用 PBKDF2）。
- 所有 GitHub 文件（构建列表、二进制、`qb_password_gen`）默认通过 `-g` 指定的加速代理拉取，
  方式为在原始 GitHub 链接前拼接代理前缀（如 `https://ghfast.top/https://raw.githubusercontent.com/...`）。
  国内服务器保持默认即可；网络能直连 GitHub 的用更快，可用 `-g ""` 关闭代理。
- 构建菜单优先通过 GitHub API 实时获取。若被限流（未认证 API 限 60 次/小时/IP），脚本会回退到随仓库附带的
  `builds-x86_64.txt` / `builds-ARM64.txt` 清单。当 `Seedbox-Components-P` 新增构建后，按下面命令重新生成清单：

  ```bash
  for a in x86_64 ARM64; do
    gh api "repos/SAGIRIxr/Seedbox-Components-P/contents/Torrent%20Clients/qBittorrent/$a" \
      --jq '.[] | select(.type=="dir") | .name' | grep '^qBittorrent-' | sort -V > "builds-$a.txt"
  done
  ```
