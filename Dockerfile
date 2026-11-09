###############################################################################
# Claude Desktop over Xpra
#
#   基础镜像  : Ubuntu 24.04 (noble)
#   应用      : Anthropic 官方 Linux 版 Claude Desktop (.deb)
#   远程显示  : Xpra 官方源 (https://xpra.org)，内置 HTML5 客户端
#   代理      : Clash Verge Rev（容器内运行，窗口同样经 Xpra 转发）
#
# 构建产物是一个可以被任意电脑访问的容器：宿主机上不需要安装任何图形
# 环境，客户端只需要一个现代浏览器，或一个原生 Xpra 客户端。
#
# 所有下载都带重试和回退源，不假设构建环境能直连任何单一站点。
###############################################################################
FROM ubuntu:24.04

LABEL org.opencontainers.image.title="claude-desktop-xpra" \
      org.opencontainers.image.description="Claude Desktop running in a container, streamed to any browser or Xpra client" \
      org.opencontainers.image.documentation="https://github.com/Xpra-org/xpra" \
      org.opencontainers.image.licenses="MIT"

ARG DEBIAN_FRONTEND=noninteractive

# Xpra 官方 APT 源对应的发行版代号，Ubuntu 24.04 为 noble
ARG XPRA_SUITE=noble
# 固定的 Claude Desktop 版本；留空表示安装官方索引中的最新版
ARG CLAUDE_DESKTOP_VERSION=
# Clash Verge Rev 版本号（对应 GitHub Release 的 tag，不带 v）
ARG CLASH_VERGE_VERSION=2.5.10
# 是否安装中日韩字体（中文界面需要），设为 false 可减小镜像体积
ARG INSTALL_CJK_FONTS=true
# 是否安装内置浏览器。Claude Desktop 的 OAuth 登录要打开一个浏览器，且回调
# 落在容器本机，所以浏览器必须装在容器里；设为 false 可显著减小镜像。
ARG INSTALL_BROWSER=true
# 是否安装 Clash Verge Rev（容器内代理客户端，窗口同样经 Xpra 转发）
ARG INSTALL_CLASH_VERGE=true

# Ubuntu 镜像站，留空则用官方 archive.ubuntu.com / ports.ubuntu.com。
# 官方源连续失败时 apt-install 会自动切换到这里的地址。
# 注意用 http://，因为基础镜像里还没有 ca-certificates。
ARG APT_MIRROR=http://mirrors.aliyun.com
# GitHub 下载失败时依次尝试的加速前缀（空格分隔，按顺序回退）
ARG GITHUB_MIRRORS="https://ghfast.top/ https://gh-proxy.com/ https://ghproxy.net/ https://gh.llkk.cc/"

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LANGUAGE=zh_CN:zh \
    TZ=UTC \
    XDG_RUNTIME_DIR=/tmp/runtime-claude \
    XPRA_DISPLAY=:100 \
    XPRA_PORT=14500 \
    XPRA_HTML=on \
    XPRA_SOCKET_DIR=/tmp/xpra

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

###############################################################################
# 0. 网络层
#
# 装一个 apt-install 包装：每次 apt 操作先重试 3 次，仍失败就把 Ubuntu 源
# 换成 APT_MIRROR（默认阿里云，可用 ARG 覆盖），再试一次。这样构建不会因为
# 官方源的偶发超时/解析失败直接崩掉。
###############################################################################
RUN set -eux; \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\nAcquire::https::Timeout "60";\n' \
        > /etc/apt/apt.conf.d/80-network; \
    printf '%s\n' \
      '#!/bin/bash' \
      'set -euo pipefail' \
      'install_pkgs() {' \
      '    apt-get update' \
      '    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"' \
      '}' \
      'try=1' \
      'while [ "$try" -le 3 ]; do' \
      '    if install_pkgs "$@"; then exit 0; fi' \
      '    echo "[apt-install] 第 ${try} 次失败，等待后重试" >&2' \
      '    try=$((try + 1))' \
      '    sleep $((try * 5))' \
      'done' \
      'base="${APT_MIRROR:-}"' \
      'if [ -n "$base" ]; then' \
      '    echo "[apt-install] 官方源持续失败，切换到 ${base}" >&2' \
      '    base="${base%/}"' \
      '    for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do' \
      '        [ -f "$f" ] || continue' \
      '        sed -i \' \
      '            -e "s|http://archive.ubuntu.com/ubuntu|${base}/ubuntu|g" \' \
      '            -e "s|http://security.ubuntu.com/ubuntu|${base}/ubuntu|g" \' \
      '            -e "s|http://ports.ubuntu.com/ubuntu-ports|${base}/ubuntu-ports|g" \' \
      '            "$f"' \
      '    done' \
      '    install_pkgs "$@"' \
      'else' \
      '    echo "[apt-install] 没有配置 APT_MIRROR，放弃" >&2' \
      '    exit 1' \
      'fi' \
      > /usr/local/bin/apt-install; \
    chmod 0755 /usr/local/bin/apt-install

###############################################################################
# 1. 基础运行时：X11 虚拟屏、D-Bus、健康检查工具
###############################################################################
RUN apt-install \
        ca-certificates \
        curl \
        dbus \
        dbus-x11 \
        libsecret-1-0 \
        tini \
        x11-utils \
        xauth \
        xvfb \
    && rm -rf /var/lib/apt/lists/*

###############################################################################
# 2. Xpra（含 X11 服务端与 HTML5 客户端）
#
# Ubuntu 自带的 xpra 只有 3.1.5，过于陈旧；这里使用 Xpra 官方 APT 源。
###############################################################################
RUN set -eux; \
    install -d -m 0755 /usr/share/keyrings; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 \
        https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc; \
    echo "deb [signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org ${XPRA_SUITE} main" \
        > /etc/apt/sources.list.d/xpra.list; \
    apt-install \
        xpra \
        xpra-codecs-extras \
        xpra-html5 \
        xpra-x11; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 3. Claude Desktop
#
# 主源：Anthropic 官方 APT 索引（官方源没有可直接引用的 KEY.gpg，所以按索引
#       解析出 .deb 路径再安装）。
# 回退 1：官方源不可达时，改用 aaddrick/claude-desktop-debian 重新打包的同一份
#         app.asar，经 GitHub 加速前缀下载。
# 回退 2：把安装包放进构建目录的 dist/（离线构建），优先使用本地文件。
#
# 官方包提供 claude-desktop，社区重打包版提供 claude-desktop-unofficial；
# 安装后统一成一个命令名，start-session.sh 才能无差别启动。
###############################################################################
COPY dist/ /tmp/dist/

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    fetch() { curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -m 900 "$1" -o "$2"; }; \
    fetch_resumable() { curl -fL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 --continue-at - -o "$2" "$1"; }; \
    fetch_gh() { \
        for prefix in "" ${GITHUB_MIRRORS}; do \
            echo "尝试下载源: ${prefix:-直连}https://github.com/$1"; \
            if fetch_resumable "${prefix}https://github.com/$1" "$2"; then return 0; fi; \
        done; \
        return 1; \
    }; \
    if [ -f /tmp/dist/claude-desktop.deb ]; then \
        echo "使用本地安装包 dist/claude-desktop.deb"; \
        cp /tmp/dist/claude-desktop.deb /tmp/claude-desktop.deb; \
    else \
        deb_url=""; \
        if fetch "https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-${arch}/Packages" /tmp/claude-Packages; then \
            if [ -n "${CLAUDE_DESKTOP_VERSION}" ]; then \
                case "${CLAUDE_DESKTOP_VERSION}" in \
                    *[!0-9.]*) echo "CLAUDE_DESKTOP_VERSION 只能包含数字和点号" >&2; exit 1;; \
                esac; \
                filename="$(grep -E "^Filename: .*/claude-desktop_${CLAUDE_DESKTOP_VERSION}_${arch}\.deb$" /tmp/claude-Packages | awk '{print $2}')"; \
            else \
                filename="$(grep -E '^Filename: .*/claude-desktop_[0-9][^/]*\.deb$' /tmp/claude-Packages | awk '{print $2}' | sort -V | tail -n 1)"; \
            fi; \
            if [ -n "${filename}" ]; then \
                deb_url="https://downloads.claude.ai/claude-desktop/apt/stable/${filename}"; \
            fi; \
        fi; \
        if [ -n "${deb_url}" ] && fetch "${deb_url}" /tmp/claude-desktop.deb; then \
            echo "使用 Anthropic 官方安装包: ${deb_url}"; \
        else \
            echo "官方源不可用，回退到 GitHub 重新打包版本"; \
            fetch "https://api.github.com/repos/aaddrick/claude-desktop-debian/releases/latest" /tmp/claude-release.json; \
            path="$(grep -o "https://github.com/[^\"]*claude-desktop-unofficial_[^\"]*_${arch}\.deb" /tmp/claude-release.json | head -n 1 | sed 's|^https://github.com/||')"; \
            if [ -z "${path}" ]; then echo "找不到可用的回退安装包" >&2; exit 1; fi; \
            fetch_gh "${path}" /tmp/claude-desktop.deb; \
        fi; \
    fi; \
    apt-install /tmp/claude-desktop.deb; \
    if ! command -v claude-desktop >/dev/null 2>&1; then \
        if command -v claude-desktop-unofficial >/dev/null 2>&1; then \
            ln -sf /usr/bin/claude-desktop-unofficial /usr/local/bin/claude-desktop; \
        else \
            echo "安装完成后找不到 claude-desktop 可执行文件" >&2; exit 1; \
        fi; \
    fi; \
    rm -f /tmp/claude-desktop.deb /tmp/claude-Packages /tmp/claude-release.json; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 4. 字体（中文界面必需）
###############################################################################
RUN set -eux; \
    if [ "${INSTALL_CJK_FONTS}" = "true" ]; then \
        apt-install fonts-dejavu-core fonts-liberation fonts-noto-cjk fonts-noto-color-emoji; \
    else \
        apt-install fonts-dejavu-core fonts-liberation; \
    fi; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 5. 内置浏览器（用于 Claude Desktop 的 OAuth 登录）
#
# 登录流程会把回调打到容器内的 127.0.0.1，因此不能借助客户端机器的浏览器，
# 必须在同一个 Xpra 会话里打开登录页。Epiphany 基于 WebKitGTK，体积适中。
###############################################################################
RUN set -eux; \
    if [ "${INSTALL_BROWSER}" = "true" ]; then \
        apt-install epiphany-browser; \
    fi; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 6. gsettings / dconf
#
# Clash Verge 切换 Sidecar 前会用 gsettings 关闭系统代理，容器里默认没有这个
# 命令，会导致回退直接失败：
#   "继续使用 Sidecar 失败: ... missing command `gsettings`"
###############################################################################
RUN apt-install dconf-cli dconf-gsettings-backend libglib2.0-bin \
    && rm -rf /var/lib/apt/lists/*

###############################################################################
# 7. Clash Verge Rev（容器内代理客户端）
#
# GitHub 直连常常不通，这里按 GITHUB_MIRRORS 依次回退；部分加速镜像会截断
# 长连接，所以用断点续传。也可以把 .deb 放进 dist/ 直接离线构建。
###############################################################################
RUN set -eux; \
    if [ "${INSTALL_CLASH_VERGE}" = "true" ]; then \
        arch="$(dpkg --print-architecture)"; \
        case "${arch}" in \
            amd64|arm64) : ;; \
            *) echo "Clash Verge Rev 不支持架构: ${arch}" >&2; exit 1 ;; \
        esac; \
        deb="Clash.Verge_${CLASH_VERGE_VERSION}_${arch}.deb"; \
        if [ -f /tmp/dist/clash-verge.deb ]; then \
            echo "使用本地安装包 dist/clash-verge.deb"; \
            cp /tmp/dist/clash-verge.deb "/tmp/${deb}"; \
        else \
            path="clash-verge-rev/clash-verge-rev/releases/download/v${CLASH_VERGE_VERSION}/${deb}"; \
            ok=0; \
            for prefix in "" ${GITHUB_MIRRORS}; do \
                echo "尝试下载源: ${prefix:-直连}https://github.com/${path}"; \
                if curl -fL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 \
                        --continue-at - -o "/tmp/${deb}" "${prefix}https://github.com/${path}"; then \
                    ok=1; break; \
                fi; \
            done; \
            if [ "${ok}" != "1" ]; then echo "Clash Verge 所有下载源都失败" >&2; exit 1; fi; \
        fi; \
        apt-install "/tmp/${deb}"; \
        rm -f "/tmp/${deb}"; \
        rm -rf /var/lib/apt/lists/*; \
    fi

###############################################################################
# 8. 非 root 运行用户
#
# Electron 的 Chromium 沙箱要求以普通用户运行；.deb 自带的 chrome-sandbox
# 已经是 root:root 4755，因此默认不需要 --no-sandbox。
# 注意：ubuntu:24.04 自带 uid/gid 1000 的 ubuntu 用户，先移除才能复用 1000。
###############################################################################
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupdel ubuntu 2>/dev/null || true; \
    groupadd -g 1000 claude; \
    useradd -m -u 1000 -g 1000 -s /bin/bash claude; \
    mkdir -p \
        /home/claude/.config/Claude \
        /home/claude/.local/share \
        /home/claude/.cache \
        /tmp/runtime-claude \
        /tmp/xpra; \
    install -d -m 1777 /tmp/.X11-unix; \
    chmod 0700 /tmp/runtime-claude /tmp/xpra; \
    chown -R 1000:1000 /home/claude /tmp/runtime-claude /tmp/xpra; \
    rm -rf /tmp/dist

COPY scripts/ /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
              /usr/local/bin/start-session.sh \
              /usr/local/bin/open-browser.sh

ENV HOME=/home/claude \
    BROWSER=/usr/local/bin/open-browser.sh

USER claude
WORKDIR /home/claude

EXPOSE 14500

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${XPRA_PORT}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
