# GUIDE — 面向 AI Agent 的部署与配置手册

> 这份文档写给需要**动手把项目跑起来**的 AI Agent。人类用户看 [README.md](README.md)。
> 每一节都给出命令和**期望输出**：如果实际输出不符，跳到 [§10 故障处置](#10-故障处置)。

---

## 部署方式：先做这个选择

两种模式用同一个镜像，**在 §2 生成 `.env` 时就要定下来**。

| | A. 本地部署 | B. 海外服务器 |
| --- | --- | --- |
| 隔离性 | 容器与本地环境完全隔离，宿主机不用装任何依赖 | 同样的隔离 |
| 网络 | 走宿主机出口；宿主机开着 TUN 代理时容器流量已被接管 | 直连 Claude，无地区限制，最稳 |
| 成本 | 用已有机器，零额外成本 | 一台服务器可跑多实例，摊薄到每人很低 |
| 访问 | 本机 / 局域网 | 公网，必须密码 + TLS |
| `ENABLE_PROXY` | `auto`（让容器自己判断） | 通常 `0`，海外直连即可 |
| `ENABLE_CLASH_VERGE` | 要改订阅时 `1` | 通常 `0`，省内存 |

### B 模式的额外要求

1. `.env` 里**固定** `XPRA_PASSWORD`，不要依赖日志里的随机密码
2. 前置 Caddy / Nginx 做 TLS，反代到 `127.0.0.1:14500`
3. 安全组只放行 443，不要把 14500 直接暴露到公网
4. 需要多人共用时按下面的方式起多实例

### 多实例

compose 里没有固定 `container_name`，用 `-p` 指定项目名即可起多套，
容器、数据卷、密码互相独立：

```bash
XPRA_PORT=14500 docker compose -p claude-a up -d
XPRA_PORT=14501 docker compose -p claude-b up -d
```

- 数据卷：`claude-a_claude-data`、`claude-b_claude-data`
- 后续所有命令把 `docker compose` 换成 `docker compose -p claude-a` 即可
- 反向代理按域名或路径分流到各自的 `XPRA_PORT`

---

## 0. 目标与约束

把 Claude Desktop 跑在容器里，通过 Xpra 转发到一个可访问的端口；必要时让容器的 Claude 走容器内的 Clash。

**你必须知道的三个硬约束**（都是实测结论，不要试图绕过）：

| 约束 | 原因 |
| --- | --- |
| Clash 的「继续使用 SIDECAR」必须由**客户端**点击 | Clash Verge 在没有 systemd 的环境里只能 Sidecar，而这个确认是会话级的。容器内用 XTEST 注入的点击**到不了 Clash 窗口**（Xpra 只把注入事件送给它自己认定的焦点窗口），实测无效 |
| 不能给 Claude 指一个没人监听的代理端口 | `ENABLE_PROXY=1` 但内核没起来时，Claude 会直接报 `ERR_PROXY_CONNECTION_FAILED`，并且进入「不再自动重试」状态 |
| Xpra 认证必须用 `file:filename=...` | `--tcp-auth=password` **不会**读取 `--password-file`，会导致所有登录被拒（日志 `no password defined for 'claude'`） |

---

## 1. 前置检查

```bash
docker --version && docker compose version
```

要求 Docker 24+ 与 compose v2。命令都在**仓库根目录**执行。

网络：构建时需要访问 `downloads.claude.ai`、`xpra.org`、`github.com`。不通也能构建——[Dockerfile](Dockerfile) 内置了三级回退（见 §3）。

---

## 2. 生成 `.env`

```bash
cp .env.example .env
```

关键项及其语义：

```ini
XPRA_PORT=14500         # 宿主机端口；容器内固定 14500
XPRA_BIND=0.0.0.0       # 0.0.0.0 = 局域网可访问；127.0.0.1 = 仅本机
XPRA_PASSWORD=          # 留空 = 首次启动随机生成并持久化到卷里

ENABLE_CLASH_VERGE=1    # 1 = Clash GUI 随容器自启（需要人工点一次 Sidecar）
                        # 0 = 不启动 GUI，内核由容器托管（零点击，但没有窗口）
ENABLE_PROXY=auto       # auto = 见 §8；1 = 强制走容器内代理；0 = 强制直连
```

---

## 3. 准备镜像

两条路，选一条。

### A. 本地构建

```bash
docker compose build
```

**期望**：最后一行是 `Image claude-desktop-xpra:latest Built`。

构建内置的回退链：

1. Ubuntu 源失败 3 次 → 自动切 `APT_MIRROR`（默认阿里云）
2. Claude Desktop 官方源不通 → 切 GitHub `aaddrick/claude-desktop-debian`
3. Clash Verge 直连失败 → 依次尝试 `GITHUB_MIRRORS` 里的加速前缀，全部断点续传

如果构建卡在下载，把安装包放进 `dist/` 再构建即可完全跳过下载：

```bash
dist/claude-desktop.deb    # Claude Desktop 的 .deb
dist/clash-verge.deb       # Clash Verge 的 .deb
```

### B. 导入现成镜像

```bash
docker load < dist/claude-desktop-xpra-<日期>.tar.gz
```

包内同时带 `latest` 和 `working` 两个 tag，导入后 `docker compose up -d` 不会触发重建。

---

## 4. 启动并确认健康

```bash
docker compose up -d
docker compose ps --format 'state={{.State}} health={{.Health}}'
```

**期望**：`state=running health=healthy`。

刚启动 60 秒内可能显示 `health=starting`，这是 healthcheck 的 `start-period`，等待即可。

---

## 5. 取访问地址与密码

```bash
docker compose logs --no-color | grep 密码
```

**期望**：`[entrypoint] 登录密码 : <16 位十六进制>`

地址二选一（都能用，第二个不随 IP 变化）：

```
http://<宿主机局域网IP>:14500/
http://<主机名>.local:14500/
```

---

## 6. 用浏览器连上会话

打开页面 → 输入**任意用户名** + 上面的密码 → Connect。

**期望**：出现 Claude Desktop 的窗口（`ENABLE_CLASH_VERGE=1` 时还会有 Clash 窗口）。

常见偏差：

| 现象 | 处置 |
| --- | --- |
| `No password specified for authentication challenge` | 重新连接，密码填在弹窗里 |
| 页面能开但一片空白、没有窗口 | 刷新页面重连（服务端窗口还在，是客户端丢了列表） |
| 完全连不上 | 确认端口映射：`docker compose ps --format '{{.Ports}}'` |

---

## 7. 配置 Clash 订阅（只有需要代理时才做）

### 7.1 确认 GUI 状态

```bash
docker compose exec claude-desktop bash -lc 'pgrep -c -x clash-verge; pgrep -c -x verge-mihomo'
```

- `1 0`：GUI 在跑，内核还没起 → 继续 7.2
- `1 1`：都已经在跑 → 跳到 7.3

### 7.2 点掉 Sidecar 确认

在浏览器里的 Clash Verge 窗口点「**继续使用 SIDECAR**」。

**这一步无法自动化**（见 §0）。如果窗口被 Claude 挡住，先在客户端里把它切到前面。

点完再验证：

```bash
docker compose exec claude-desktop bash -lc '(exec 3<>/dev/tcp/127.0.0.1/7897) 2>/dev/null && echo open || echo closed'
```

**期望**：`open`。

> GUI 没随容器启动时，先执行 `make clash`：它会先停掉容器托管的内核，再打开 GUI，
> 这样 Sidecar 才能点成功——内核被占用时点它会报「已有内核进程正在运行」。

### 7.3 导入订阅

在 Clash Verge 窗口里：订阅 → 新建 → 粘贴订阅链接 → 导入 → 选一个能用的节点。

验证节点是否真的可用（`delay` 有数字才算通）：

```bash
dir=/home/claude/.local/share/io.github.clash-verge-rev.clash-verge-rev
docker compose exec -T claude-desktop bash -lc "
curl -s --unix-socket $dir/verge-mihomo.sock -H 'Authorization: Bearer set-your-secret' \
  'http://localhost/proxies/<URL编码后的节点名>/delay?timeout=5000&url=https://www.gstatic.com/generate_204'"
```

---

## 8. 决定 Claude 走不走容器内代理

`ENABLE_PROXY` 的三种取值：

| 值 | 行为 |
| --- | --- |
| `auto`（默认） | 满足「订阅已启用」+「7897 在监听」后，先探测直连：`api.anthropic.com` 或 `claude.ai` 任一可达就**直连**，否则走容器内代理 |
| `1` | 无条件给 Claude 注入 `http_proxy` / `https_proxy` |
| `0` | 从不注入 |

**为什么 `auto` 优先直连**：宿主机若本身开着 TUN 代理，容器流量已经被接管，再套一层容器内 Clash 等于多一跳、多一组可能挂掉的节点，实测表现为「代理时好时坏」。

**什么时候必须用 `1`**：直连虽然通，但 Claude 界面显示 **`App unavailable in region`** ——说明出口地区不对，必须换到代理节点。

改完要重启才生效：

```bash
docker compose up -d          # 改了 .env
```

---

## 9. 验证清单

按顺序跑，全部符合才算配置完成。

```bash
# 1. 容器健康
docker compose ps --format 'state={{.State}} health={{.Health}}'          # running healthy

# 2. 代理变量（ENABLE_PROXY=1 时应有输出）
docker compose exec -T claude-desktop bash -lc \
  'pid=$(pgrep -x claude-desktop | head -1); tr "\0" "\n" < /proc/$pid/environ | grep https_proxy'

# 3. 会话日志里的代理决策
docker compose logs --no-color | grep -E '代理|直连' | tail -2

# 4. 经容器代理访问 Claude（403/404 都算通，000 才算失败）
docker compose exec -T claude-desktop bash -lc \
  'curl -x http://127.0.0.1:7897 -sS -m 20 -o /dev/null -w "%{http_code}\n" https://claude.ai'

# 5. Claude 的流量确实经过 mihomo（ENABLE_PROXY=1 时）
docker compose exec -T claude-desktop bash -lc \
  'grep -E "claude\.ai|anthropic\.com" ~/.cache/claude-xpra/mihomo.log | tail -3'
```

第 5 条**期望**形如：

```
[TCP] 127.0.0.1:47580 --> api.anthropic.com:443 match RuleSet(claude) using 🤖 AI服务
```

> `claude.ai` 返回 **403** 是 Cloudflare 对 curl 的正常响应，代表可达；
> **000** 才是连不上。`api.anthropic.com` 返回 404 同理。

---

## 10. 故障处置

| 现象 | 根因 | 处置 |
| --- | --- | --- |
| `no password defined for 'claude'` | 用了 `--tcp-auth=password` | 必须用 `file:filename=<密码文件>`，已在 entrypoint 修好 |
| 容器无限重启，日志 `Server is already active for display 100` | restart 保留了 `/tmp`，残留 X lock | entrypoint 已清理；若手工改过脚本，别删这段 |
| Clash 弹窗「已有内核进程正在运行」 | 容器托管内核与 GUI 抢 7897 | 用 `make clash` 打开 GUI（它会先停内核） |
| `ERR_PROXY_CONNECTION_FAILED` | `ENABLE_PROXY=1` 但 7897 没监听 | 先点 Sidecar 把内核拉起来，再点 Claude 页面的「重新加载」 |
| `App unavailable in region` | 直连出口地区不对 | 走代理（`ENABLE_PROXY=1` + 可用节点） |
| Clash 解锁测试里 Claude ❌ | 节点本身过不了 Claude | 换节点，与本项目无关 |
| 浏览器页面变回 `connect.html` | 客户端掉线 | 刷新重连，服务端不受影响 |
| 构建卡在下载 | 网络 | 见 §3 的回退与 `dist/` 离线方案 |

诊断命令速查：

```bash
docker compose logs --no-color --tail=50 | grep -iE 'error|fail|auth'
docker compose exec -T claude-desktop bash -lc 'DISPLAY=:100 xwininfo -root -tree | grep -E "Claude|Clash"'
docker compose exec -T claude-desktop bash -lc 'tail -20 ~/.cache/claude-xpra/clash-verge.log'
docker compose exec -T claude-desktop bash -lc 'tail -20 ~/.cache/claude-xpra/mihomo.log'
docker compose exec -T claude-desktop bash -lc 'tail -20 ~/.config/Claude/logs/main.log'
```

---

## 11. 原生 Xpra 客户端（可选）

macOS（无 Homebrew 也可，实测路径）：

```bash
printf '%s' '<密码>' > ~/.xpra-pass && chmod 600 ~/.xpra-pass
/Applications/Xpra.app/Contents/MacOS/Xpra attach tcp://<host>:14500/ --password-file=$HOME/.xpra-pass
```

**注意**：`--password=` 不被识别，会弹图形密码框；必须用 `--password-file`。

断开后会话仍在，重新 attach 回到原状态。

---

## 12. 分发镜像

```bash
make verify-clean     # 期望：镜像干净：无登录态、无订阅配置
make save             # 产出 dist/claude-desktop-xpra-<日期>.tar.gz
```

**镜像是干净的**：Clash 订阅、Claude 登录态、访问密码全在 `claude-data` 卷里，
`docker save` 只打包镜像层。

**不要**把 `claude-data` 卷一起分发——那里面才是隐私数据。

---

## 13. 文件职责

| 文件 | 作用 |
| --- | --- |
| `Dockerfile` | Ubuntu 24.04 + Xpra + Claude Desktop + Clash Verge，含多源回退与 `apt-install` 重试包装 |
| `docker-compose.yml` | 端口、卷、`seccomp=unconfined`（Chromium 需要）、`shm_size` |
| `scripts/entrypoint.sh` | 生成/读取密码、清理 X lock、启动 Xpra（`file` 认证 + HTML5） |
| `scripts/start-session.sh` | 会话编排：GUI、托管内核、代理决策、启动 Claude |
| `scripts/clash-gui.sh` | 打开 Clash GUI 前先停掉托管内核 |
| `scripts/open-browser.sh` | OAuth 登录用的浏览器入口（Epiphany） |
| `dist/` | 离线安装包与导出的镜像（已在 `.gitignore` 里） |

---

## 14. 不要做的事

- 不要提交 `.env`（已在 `.gitignore`）
- 不要把 `claude-data` 卷打包分发
- 不要把 `--tcp-auth` 改回 `password`
- 不要去掉 compose 里的 `seccomp=unconfined`（Chromium 的 zygote 会起不来）
- 不要让容器托管内核和 Clash GUI 同时占用 7897
- 不要假设容器内能自动点 Clash 的 Sidecar —— 实测不可行
