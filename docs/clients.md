# 各平台客户端连接说明

服务端只暴露一个 TCP 端口（默认 `14500`），它同时支持：

- Xpra 原生协议（`tcp://`）
- HTML5 客户端（HTTP，浏览器直接访问）
- WebSocket（`ws://`，可选）

## 浏览器（无需安装）

打开 `http://<宿主机IP>:14500/`，输入用户名（任意）和密码。

- 支持 Chrome / Edge / Safari / Firefox 的较新版本
- 建议用「添加到桌面 / 全屏」获得接近原生应用的体验
- 走 HTTPS 反代时，记得反代要支持长连接

## macOS

```bash
brew install --cask xpra
xpra attach tcp://<宿主机IP>:14500/
```

常用参数：

```bash
# 只显示应用窗口（seamless），而不是整个桌面
xpra attach --mmap=no tcp://<宿主机IP>:14500/

# 指定缩放与编码
xpra attach --encodings=h264,vp9,png tcp://<宿主机IP>:14500/
```

## Windows

从 <https://xpra.org/> 下载安装包，然后：

```powershell
xpra attach tcp://<宿主机IP>:14500/
```

首次连接会提示输入密码。

## Linux

发行版仓库里的 xpra 往往版本较老，推荐用官方源（和服务端镜像用的是同一个源）：

```bash
sudo dnf install xpra            # Fedora
sudo apt install xpra            # Debian / Ubuntu（版本较旧，功能仍可用）
xpra attach tcp://<宿主机IP>:14500/
```

## 连接行为说明

- **断开不断会话**：关掉客户端或拔网线，Claude Desktop 仍留在容器里运行；重新 `attach` 即可回到原来的窗口状态。
- **多端同时连接**：默认允许，多个客户端会看到同一个会话。
- **剪贴板**：双向同步，受浏览器/客户端安全策略限制。
- **音频**：需要客户端支持；浏览器端要用户交互后才允许播放。
- **打印**：Xpra 支持把容器里的打印任务转发到客户端，原生客户端可用。

## 排错

```bash
# 服务端看会话状态
docker compose exec claude-desktop xpra info :100

# 看 HTML5 是否在监听
docker compose exec claude-desktop curl -fsS http://127.0.0.1:14500/ | head
```

浏览器能打开页面但连不上会话，通常是密码不对或端口被反代吞掉了长连接。
