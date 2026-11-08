#!/usr/bin/env bash
#
# Xpra 的子会话：先起一个轻量窗口管理器，再前台运行 Claude Desktop。
#
# Xpra 用 --exit-with-children=yes 启动本脚本，因此进程退出时整个 Xpra
# 会话随之结束，容器按 restart 策略重启，状态保存在挂载卷里不会丢。
#
set -euo pipefail

log() { printf '[session] %s\n' "$*"; }

export DISPLAY="${DISPLAY:-:100}"
export GDK_BACKEND=x11
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=openbox
export DESKTOP_SESSION=openbox
export ELECTRON_OZONE_PLATFORM_HINT=x11

# 容器里通常没有可用 GPU，软件渲染更稳定；有显卡时可设 CLAUDE_GPU=1 覆盖。
if [[ "${CLAUDE_GPU:-0}" != "1" ]]; then
    export LIBGL_ALWAYS_SOFTWARE=1
fi

# 窗口管理器：让 Electron 窗口能正常最大化、最小化并带边框。
if command -v openbox >/dev/null 2>&1; then
    openbox --sm-disable >/dev/null 2>&1 &
    log "openbox 已启动 (pid $!)"
fi

# 传递给 Claude Desktop 的额外参数，例如 CLAUDE_ARGS="--no-sandbox"
app_args=()
if [[ -n "${CLAUDE_ARGS:-}" ]]; then
    read -r -a app_args <<< "${CLAUDE_ARGS}"
fi

log "启动 Claude Desktop..."
exec claude-desktop "${app_args[@]}"
