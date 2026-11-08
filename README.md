# openAnt

在 Docker 里运行 **Claude Desktop**，通过 [Xpra](https://github.com/Xpra-org/xpra) 把它的图形界面转发到**任何一台电脑**——客户端只需要一个浏览器，或者一个原生 Xpra 客户端。宿主机不需要安装任何桌面环境、X11 或显卡驱动。

## 它是怎么工作的

```
                    ┌──────────────────── Docker 容器 ─────────────────────┐
   浏览器 / 原生      │                                                      │
   Xpra 客户端        │   ┌────────┐   ┌──────────────┐   ┌───────────────┐  │
        │            │   │  Xpra  │──▶│     Xvfb     │◀──│     Claude    │  │
        │  TCP 14500 │   │ server │   │  虚拟 X11    │   │    Desktop    │  │
        └───────────▶│   │  + HTML5│  │   显示 :100  │   ├───────────────┤  │
                     │   └────────┘   └──────┬───────┘   │  Clash Verge  │  │
                     │                       │           │   （代理）     │  │
                     │            Xpra seamless 窗口管理  └───────────────┘  │
                     │                                                      │
                     │   Epiphany 浏览器（仅在容器内完成 OAuth 登录）         │
                     └──────────────────────────────────────────────────────┘
```

- **Xvfb** 提供一块虚拟屏幕，不需要真实显示器。
- **Xpra** 把这块屏幕上的窗口变化编码成 Xpra 协议；同一个端口还内置了 **HTML5 客户端**，所以浏览器直接访问 `http://<主机>:14500/` 就能用。
- Xpra 的 seamless 模式**自带窗口管理**，每个顶层窗口单独转发，不需要额外装窗口管理器。
- **Clash Verge Rev**（可选）跑在同一个会话里，订阅、节点、规则都在浏览器里直接配，Claude Desktop 通过它的混合端口出网。
- 断开连接后 Claude Desktop 仍在容器里运行，重新连上即可继续——这是 Xpra 相对 VNC 的核心优势。

## 前置条件

- Docker（含 `docker compose`）
- 构建时能访问 `downloads.claude.ai`（Claude Desktop 官方源）、`xpra.org`（Xpra 官方源）和 `github.com`（Clash Verge 的发布包）

## 快速开始

```bash
git clone <本仓库地址> openAnt
cd openAnt
cp .env.example .env
docker compose up -d --build
```

查看访问密码：

```bash
docker compose logs claude-desktop | grep 密码
```

浏览器打开 `http://<宿主机IP>:14500/`，用户名随意填（例如 `claude`），密码用上一步日志里的值。

首次构建要下载约 600 MB 的 Claude Desktop 安装包，耗时取决于网络。

### 用原生 Xpra 客户端连接

HTML5 客户端够用，但原生客户端的延迟、缩放和快捷键体验更好：

```bash
# macOS
brew install --cask xpra

# 连接
xpra attach tcp://192.168.1.10:14500/
```

Windows 和 Linux 的安装包见 [Xpra 下载页](https://xpra.org/)，更细的客户端说明见 [docs/clients.md](docs/clients.md)。

## 首次登录

Claude Desktop 使用 OAuth 登录：点击「登录」后，它会在容器内唤起浏览器打开登录页。这个浏览器（Epiphany）就在同一个 Xpra 会话里，所以**你会看到登录页出现在 Claude 窗口旁边**，直接在里面登录即可。

登录态保存在 Docker 卷 `claude-data` 的 `/home/claude/.config/Claude` 下，容器重启不会丢失。

> 浏览器必须装在容器里，因为 OAuth 的回调地址指向容器自己的 `127.0.0.1`。如果把 `INSTALL_BROWSER` 设为 `false`，就只能先在别的 Linux 机器上登录，再把 `~/.config/Claude` 拷贝进卷里。

## 在容器里配置 Clash Verge 代理

镜像内置了 [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)，它的窗口和 Claude Desktop 一起经 Xpra 转发，所以整个代理配置过程都能在浏览器里完成。

1. 打开 `http://<宿主机IP>:14500/`，会同时看到 Claude Desktop 和 Clash Verge 两个窗口。
2. 在 Clash Verge 里打开「订阅」→ 新建，粘贴订阅链接并导入。
3. 在「代理」里选一个节点，确认「设置」里的**混合端口**（默认 `7897`）。
4. Claude Desktop 启动时已经带上 `http_proxy` / `https_proxy` 指向这个端口，代理一就绪就能出网。

几点说明：

- 容器里没有 `NET_ADMIN` 权限，**TUN 模式用不了**；也不需要打开「系统代理」。本镜像通过 `http_proxy` 环境变量直连混合端口，这是容器里最可靠的方式。
- 端口改过之后，把 `.env` 里的 `PROXY_URL` 或 `CLASH_MIXED_PORT` 同步改掉，再 `docker compose up -d`。
- Clash Verge 的订阅与配置存在 `claude-data` 卷里，容器重建不会丢。
- 不想让 Claude 走代理：`ENABLE_PROXY=0`；不想启动 Clash 窗口：`ENABLE_CLASH_VERGE=0`。
- 首次还没导入订阅时，`ENABLE_PROXY=1` 会让 Claude 连不上网——先去 Clash 里把订阅配好即可。

## 配置项

`.env` 中的变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `XPRA_PORT` | `14500` | 对外端口 |
| `XPRA_BIND` | `0.0.0.0` | 监听地址；改成 `127.0.0.1` 则仅本机可访问 |
| `XPRA_PASSWORD` | 空 | 留空则首次启动自动生成随机密码并持久化 |
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `CLAUDE_ARGS` | 空 | 传给 Claude Desktop 的额外参数，例如 `--no-sandbox` |
| `CLAUDE_DESKTOP_VERSION` | 空 | 固定版本号（如 `4.23118.0`），留空为最新版 |
| `CLAUDE_GPU` | `0` | 设为 `1` 时不强制软件渲染 |
| `INSTALL_CJK_FONTS` | `true` | 是否安装中日韩字体 |
| `INSTALL_BROWSER` | `true` | 是否安装容器内浏览器（登录需要） |
| `INSTALL_CLASH_VERGE` | `true` | 是否安装 Clash Verge Rev |
| `CLASH_VERGE_VERSION` | `2.5.10` | Clash Verge Rev 版本 |
| `ENABLE_CLASH_VERGE` | `1` | 启动时是否拉起 Clash Verge 窗口 |
| `ENABLE_PROXY` | `1` | Claude Desktop 是否走容器内 Clash |
| `PROXY_URL` | 自动 | 代理地址；留空则读取混合端口，兜底 `http://127.0.0.1:7897` |
| `CLASH_MIXED_PORT` | 自动 | 强制指定 Clash 混合端口 |

其它可以在容器里直接传的环境变量：

| 变量 | 说明 |
| --- | --- |
| `XPRA_SSL_CERT` / `XPRA_SSL_KEY` | 同时提供时启用 TLS，浏览器改用 `https://` |
| `XPRA_TCP_AUTH` | 默认 `password`，可设 `none`（不推荐） |
| `XPRA_EXTRA_ARGS` | 追加任意 `xpra start` 参数 |

## 数据持久化

`docker-compose.yml` 使用命名卷 `claude-data` 挂载到 `/home/claude`，保存：

- `~/.config/Claude/claude_desktop_config.json` —— MCP 服务器等配置
- `~/.config/Claude/` —— 登录态与本地数据
- `~/.cache/` —— 缓存

备份：

```bash
docker run --rm -v claude-desktop-xpra_claude-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/claude-data.tgz -C /data .
```

## 安全说明

默认配置把端口开在 `0.0.0.0:14500` 上，**只适合内网使用**：

1. 一定要设置强密码，或让入口脚本自动生成。
2. 需要从公网访问时，请在前面放一层 HTTPS 反向代理（Caddy / Nginx），或者用 `XPRA_SSL_CERT` 直接启用 TLS。
3. `XPRA_TCP_AUTH=none` 等于把 Claude 账号交给任何能连上端口的人，不要用。
4. 容器内以非 root 用户 `claude`（uid 1000）运行。
5. compose 里设置了 `seccomp=unconfined`，因为 Chromium 的 zygote 需要创建
   命名空间，Docker 默认的 seccomp 策略会把它拦下来。这会削弱容器的系统调用
   过滤，属于「能在容器里跑 Electron」的常见取舍；如果你更在意隔离，可以去掉
   这一行并改用 `CLAUDE_ARGS=--no-sandbox`（关掉 Chromium 自己的沙箱）。

一个最小的 Caddy 配置：

```caddyfile
claude.example.com {
    reverse_proxy 127.0.0.1:14500
}
```

> Xpra 走的是长连接，反向代理需要支持 WebSocket / 长连接升级。Nginx 需要
> `proxy_http_version 1.1;`、`proxy_set_header Upgrade $http_upgrade;` 和
> `proxy_read_timeout 3600s;`。

## GPU（可选）

默认走软件渲染，兼容性最好。有 NVIDIA 显卡并且装了 container toolkit 时：

```yaml
# docker-compose.yml
services:
  claude-desktop:
    gpus: all
    environment:
      CLAUDE_GPU: "1"
```

## 常见问题

**页面能打开，登录后一直白屏**
容器内 Chromium 共享内存不足。确认 `shm_size: "1gb"` 生效，或给 `CLAUDE_ARGS` 加上 `--disable-dev-shm-usage`。

**Claude Desktop 启动就退出**

日志里出现 `Zygote process exited prematurely` / `Failed to move to new namespace`
说明 Chromium 沙箱被容器的安全策略挡住了：确认 compose 中的
`security_opt: [seccomp=unconfined]` 生效，或直接设 `CLAUDE_ARGS=--no-sandbox`
（会降低安全性，仅在受信环境使用）。

用 `docker run` 手工启动时对应加 `--security-opt seccomp=unconfined`。

**中文显示成方块**
确认 `INSTALL_CJK_FONTS=true`（默认），然后重新 `docker compose build`。

**Claude 一直转圈 / 无法联网**
多半是代理没配好。打开 Clash Verge 窗口确认订阅已导入、节点可用；临时排查可以先设 `ENABLE_PROXY=0` 再重启，确认是代理问题。

**Clash Verge 窗口没出现**
确认 `ENABLE_CLASH_VERGE=1` 且镜像里装了它（`INSTALL_CLASH_VERGE=true` 时需要重新 `docker compose build`）。它启动比 Claude 慢，等几秒再看。

**没有声音**
Xpra 支持音频转发，但需要客户端支持；HTML5 客户端在没有用户交互前会被浏览器阻止自动播放，点一下页面即可。

**剪贴板**
Xpra 默认双向同步剪贴板。浏览器出于安全限制可能需要你允许剪贴板读写权限。

**端口被占用**
改 `.env` 里的 `XPRA_PORT`。

## 项目结构

```
.
├── Dockerfile              # 镜像定义：Ubuntu + Xpra + Claude Desktop
├── docker-compose.yml      # 一键启动
├── .env.example            # 配置模板
├── Makefile                # 常用命令封装
├── scripts/
│   ├── entrypoint.sh       # 容器入口：准备环境 + 启动 Xpra
│   ├── start-session.sh    # Xpra 子会话：clash-verge + claude-desktop
│   └── open-browser.sh     # xdg-open 的浏览器入口
├── docs/
│   └── clients.md          # 各平台客户端连接说明
└── .github/workflows/      # 多架构镜像构建
```

## 开发

```bash
make build     # 构建镜像
make up        # 启动
make logs      # 跟踪日志
make shell     # 进入容器
make password  # 查看当前密码
make down      # 停止
make clean     # 停止并删除数据卷（会丢失登录态）
```

---

Claude Desktop 由 Anthropic 提供，本仓库只负责打包与远程显示。Xpra 以 GPLv2+ 发布，见其[上游仓库](https://github.com/Xpra-org/xpra)。
