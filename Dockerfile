# syntax=docker/dockerfile:1.7

###############################################################################
# Claude Desktop over Xpra
#
#   基础镜像  : Ubuntu 24.04 (noble)
#   应用      : Anthropic 官方 Linux 版 Claude Desktop (.deb)
#   远程显示  : Xpra 官方源 (https://xpra.org)，内置 HTML5 客户端
#
# 构建产物是一个可以被任意电脑访问的容器：宿主机上不需要安装任何图形
# 环境，客户端只需要一个现代浏览器，或一个原生 Xpra 客户端。
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
# 是否安装中日韩字体（中文界面需要），设为 false 可减小镜像体积
ARG INSTALL_CJK_FONTS=true
# 是否安装内置浏览器。Claude Desktop 的 OAuth 登录要打开一个浏览器，且回调
# 落在容器本机，所以浏览器必须装在容器里；设为 false 可显著减小镜像。
ARG INSTALL_BROWSER=true

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
# 1. 基础运行时：X11 虚拟屏、窗口管理器、D-Bus、健康检查工具
###############################################################################
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dbus \
        dbus-x11 \
        libsecret-1-0 \
        openbox \
        tini \
        x11-utils \
        xauth \
        xvfb \
    && rm -rf /var/lib/apt/lists/* \
    && printf 'Acquire::Retries "5";\nAcquire::https::Timeout "60";\n' > /etc/apt/apt.conf.d/80-network

###############################################################################
# 2. Xpra（含 X11 服务端与 HTML5 客户端）
#
# Ubuntu 自带的 xpra 只有 3.1.5，过于陈旧；这里使用 Xpra 官方 APT 源。
###############################################################################
RUN set -eux; \
    install -d -m 0755 /usr/share/keyrings; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc; \
    echo "deb [signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org ${XPRA_SUITE} main" \
        > /etc/apt/sources.list.d/xpra.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        xpra \
        xpra-codecs-extras \
        xpra-html5 \
        xpra-x11; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 3. Claude Desktop（Anthropic 官方 Linux 版 .deb）
#
# 官方 APT 源没有公开的可直接引用的 KEY.gpg，因此这里按照官方索引解析出
# 目标 .deb 的路径再安装，等价于官方给出的那条 curl 命令。
###############################################################################
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    index="https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-${arch}/Packages"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "${index}" -o /tmp/claude-Packages; \
    if [ -n "${CLAUDE_DESKTOP_VERSION}" ]; then \
        case "${CLAUDE_DESKTOP_VERSION}" in \
            *[!0-9.]*) echo "CLAUDE_DESKTOP_VERSION 只能包含数字和点号: ${CLAUDE_DESKTOP_VERSION}" >&2; exit 1;; \
        esac; \
        filename="$(grep -E "^Filename: .*/claude-desktop_${CLAUDE_DESKTOP_VERSION}_${arch}\.deb$" /tmp/claude-Packages | awk '{print $2}')"; \
    else \
        filename="$(grep -E '^Filename: .*/claude-desktop_[0-9][^/]*\.deb$' /tmp/claude-Packages | awk '{print $2}' | sort -V | tail -n 1)"; \
    fi; \
    if [ -z "${filename}" ]; then \
        echo "在官方索引中找不到可用的 Claude Desktop 安装包 (arch=${arch})" >&2; exit 1; \
    fi; \
    echo "安装 Claude Desktop: ${filename}"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 "https://downloads.claude.ai/claude-desktop/apt/stable/${filename}" -o /tmp/claude-desktop.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/claude-desktop.deb; \
    rm -f /tmp/claude-desktop.deb /tmp/claude-Packages; \
    rm -rf /var/lib/apt/lists/*

###############################################################################
# 4. 字体（中文界面必需）
###############################################################################
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        fonts-dejavu-core \
        fonts-liberation; \
    if [ "${INSTALL_CJK_FONTS}" = "true" ]; then \
        apt-get install -y --no-install-recommends \
            fonts-noto-cjk \
            fonts-noto-color-emoji; \
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
        apt-get update; \
        apt-get install -y --no-install-recommends epiphany-browser; \
        rm -rf /var/lib/apt/lists/*; \
    fi

###############################################################################
# 6. 非 root 运行用户
#
# Electron 的 Chromium 沙箱要求以普通用户运行；.deb 自带的 chrome-sandbox
# 已经是 root:root 4755，因此默认不需要 --no-sandbox。
###############################################################################
# 注意：ubuntu:24.04 自带 uid/gid 1000 的 ubuntu 用户，先移除才能复用 1000
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
    chown -R 1000:1000 /home/claude /tmp/runtime-claude /tmp/xpra

COPY --chmod=0755 scripts/ /usr/local/bin/

ENV HOME=/home/claude \
    BROWSER=/usr/local/bin/open-browser.sh

USER claude
WORKDIR /home/claude

EXPOSE 14500

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${XPRA_PORT}/" >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
