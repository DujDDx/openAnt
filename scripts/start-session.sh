#!/usr/bin/env bash
#
# Xpra 的子会话：窗口管理器 + （可选）Clash Verge + Claude Desktop。
#
# Xpra 用 --exit-with-children=yes 启动本脚本，因此 Claude Desktop 退出时
# 整个 Xpra 会话随之结束，容器按 restart 策略重启，状态保存在挂载卷里。
#
set -euo pipefail

log() { printf '[session] %s\n' "$*"; }

export DISPLAY="${DISPLAY:-:100}"
export GDK_BACKEND=x11
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=openbox
export DESKTOP_SESSION=openbox
export ELECTRON_OZONE_PLATFORM_HINT=x11

# WebKitGTK（Epiphany、Clash Verge 的界面层）在容器里建不起 bwrap 沙箱，
# 会直接崩：bwrap: Can't mount proc on /newroot/proc: Operation not permitted。
# 容器本身已经是隔离边界，这里关掉 WebKit 自带的沙箱，否则 OAuth 登录用的
# 浏览器根本起不来。
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
# 容器里没有 accessibility bus，关掉可以少两行噪音日志
export GTK_A11Y=none
export NO_AT_BRIDGE=1

# 容器里通常没有可用 GPU，软件渲染更稳定；有显卡时可设 CLAUDE_GPU=1 覆盖。
if [[ "${CLAUDE_GPU:-0}" != "1" ]]; then
    export LIBGL_ALWAYS_SOFTWARE=1
fi

# ------------------------------------------------------------ 窗口管理器 ---
log_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-xpra"
mkdir -p "${log_dir}"

# 说明：Xpra 的 seamless 模式自带窗口管理器，不需要再起 openbox
# （起了也会报 "A window manager is already running" 然后退出）。

# ------------------------------------------------------------ Clash Verge ---
# Clash Verge 自己就是出口，必须先于代理环境变量启动；否则它更新订阅的流量
# 会被绕回它自己，形成死循环。
clash_pid=""
if [[ "${ENABLE_CLASH_VERGE:-1}" != "0" ]] && command -v clash-verge >/dev/null 2>&1; then
    log "启动 Clash Verge..."
    clash-verge >"${log_dir}/clash-verge.log" 2>&1 &
    clash_pid=$!
fi

# ---------------------------------------------------------------- 代理配置 ---
# 混合端口优先取 Clash Verge 自己保存的配置，其次 CLASH_MIXED_PORT，最后默认值。
clash_data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/io.github.clash-verge-rev.clash-verge-rev"
clash_verge_yaml="${clash_data_dir}/verge.yaml"
clash_port="${CLASH_MIXED_PORT:-}"

if [[ -z "${clash_port}" && -r "${clash_verge_yaml}" ]]; then
    clash_port="$(sed -n 's/^verge_mixed_port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${clash_verge_yaml}" | head -n 1 || true)"
fi
clash_port="${clash_port:-7897}"

proxy_url="${PROXY_URL:-http://127.0.0.1:${clash_port}}"

if [[ "${ENABLE_PROXY:-1}" != "0" ]]; then
    # 等混合端口就绪，避免 Claude Desktop 在代理起来之前就去连网。
    if [[ -n "${clash_pid}" ]]; then
        clash_ready=0
        for _ in $(seq 1 15); do
            if (exec 3<>"/dev/tcp/127.0.0.1/${clash_port}") 2>/dev/null; then
                exec 3<&- 3>&-
                clash_ready=1
                break
            fi
            sleep 1
        done
        if [[ "${clash_ready}" = "1" ]]; then
            log "Clash 混合端口 127.0.0.1:${clash_port} 已就绪"
        else
            log "警告: Clash 混合端口 127.0.0.1:${clash_port} 还没有监听"
            log "      请先在 Clash Verge 窗口里导入订阅并启用配置"
        fi
    fi

    export http_proxy="${proxy_url}"   https_proxy="${proxy_url}" \
           HTTP_PROXY="${proxy_url}"   HTTPS_PROXY="${proxy_url}" \
           all_proxy="${proxy_url}"    ALL_PROXY="${proxy_url}" \
           no_proxy="localhost,127.0.0.1,::1" \
           NO_PROXY="localhost,127.0.0.1,::1"
    log "已为 Claude Desktop 设置代理: ${proxy_url}"
fi

# ------------------------------------------------------------ Claude Desktop ---
# 额外参数，例如 CLAUDE_ARGS="--no-sandbox"
app_args=()
if [[ -n "${CLAUDE_ARGS:-}" ]]; then
    read -r -a app_args <<< "${CLAUDE_ARGS}"
fi

log "启动 Claude Desktop..."
exec claude-desktop "${app_args[@]}"
