#!/usr/bin/env bash
#
# Xpra 的子会话：Clash Verge（可选）+ 代理环境变量 + Claude Desktop。
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

log_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/claude-xpra"
mkdir -p "${log_dir}"

# 说明：Xpra 的 seamless 模式自带窗口管理器，不需要再起 openbox
# （起了也会报 "A window manager is already running" 然后退出）。

# ---------------------------------------------------------------- 代理位置 ---
clash_data_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/io.github.clash-verge-rev.clash-verge-rev"
clash_runtime_config="${clash_data_dir}/clash-verge.yaml"
clash_socket="${clash_data_dir}/verge-mihomo.sock"
clash_verge_yaml="${clash_data_dir}/verge.yaml"
clash_profiles_yaml="${clash_data_dir}/profiles.yaml"

# 已经导入并启用了订阅？profiles.yaml 里 current 为 null 表示还没有。
clash_profile_active=0
if [[ -r "${clash_profiles_yaml}" ]] \
   && ! grep -qE '^current:[[:space:]]*(null)?[[:space:]]*$' "${clash_profiles_yaml}"; then
    clash_profile_active=1
fi

clash_port="${CLASH_MIXED_PORT:-}"
if [[ -z "${clash_port}" && -r "${clash_verge_yaml}" ]]; then
    clash_port="$(sed -n 's/^verge_mixed_port:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "${clash_verge_yaml}" | head -n 1 || true)"
fi
clash_port="${clash_port:-7897}"

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/${clash_port}") 2>/dev/null || return 1
    exec 3<&- 3>&-
    return 0
}

# ------------------------------------------------------------ Clash Verge ---
# 默认不启动 GUI：容器自己托管一个无界面内核，代理开箱可用，也不用处理
# 「需要更新系统服务」那个弹窗。需要改订阅时，从 Xpra 菜单打开「Clash Verge (配置)」，
# 那个入口会先停掉托管内核，再让 GUI 用 Sidecar 接管。
#
# ENABLE_CLASH_VERGE=1 可以让 GUI 开机自启，此时不再托管内核（否则 GUI 会被
# 弹窗卡住），代理需要你点一次「继续使用 SIDECAR」才会就绪。
clash_pid=""
if [[ "${ENABLE_CLASH_VERGE:-0}" != "0" ]] && command -v clash-verge >/dev/null 2>&1; then
    log "启动 Clash Verge（GUI 模式，不托管内核）..."
    clash-verge >"${log_dir}/clash-verge.log" 2>&1 &
    clash_pid=$!
fi

# ---------------------------------------------------------------- 托管内核 ---
# GUI 没开的时候，由容器自己把 mihomo 拉起来：不开窗口、不用点任何确认。
clash_wait=0
if [[ -n "${clash_pid}" ]]; then
    clash_wait=1
elif command -v verge-mihomo >/dev/null 2>&1; then
    if [[ ! -f "${clash_runtime_config}" ]]; then
        log "还没有 Clash 配置（${clash_runtime_config}），跳过托管内核"
    elif port_open; then
        log "已有 Clash 内核在监听 ${clash_port}，直接使用"
        clash_wait=1
    else
        log "启动托管内核：${clash_runtime_config}"
        verge-mihomo \
            -d "${clash_data_dir}" \
            -f "${clash_runtime_config}" \
            -ext-ctl-unix "${clash_socket}" \
            >"${log_dir}/mihomo.log" 2>&1 &
        clash_wait=1
    fi
fi

# ---------------------------------------------------------------- 代理配置 ---
proxy_url="${PROXY_URL:-http://127.0.0.1:${clash_port}}"

# ENABLE_PROXY: auto（默认）| 1 | 0
#   auto 只有在混合端口真的在监听时才让 Claude 走代理。容器本身通常就能直连，
#   给 Claude 指一个没人监听的端口只会让它的所有请求失败。
proxy_mode="${ENABLE_PROXY:-auto}"
case "${proxy_mode}" in
    0|no|false) proxy_mode=0 ;;
    1|yes|true) proxy_mode=1 ;;
    *)          proxy_mode=auto ;;
esac

clash_listening=0
if [[ "${clash_wait}" = "1" ]]; then
    for _ in $(seq 1 15); do
        if port_open; then
            clash_listening=1
            break
        fi
        sleep 1
    done
fi

if [[ "${proxy_mode}" = "auto" ]]; then
    # 端口在听、并且确实启用了订阅，才值得让 Claude 绕这一跳；
    # 否则直连更快，也少一个失败点。
    if [[ "${clash_listening}" = "1" && "${clash_profile_active}" = "1" ]]; then
        proxy_mode=1
    else
        proxy_mode=0
    fi
fi

if [[ "${proxy_mode}" = "1" ]]; then
    export http_proxy="${proxy_url}"   https_proxy="${proxy_url}" \
           HTTP_PROXY="${proxy_url}"   HTTPS_PROXY="${proxy_url}" \
           all_proxy="${proxy_url}"    ALL_PROXY="${proxy_url}" \
           no_proxy="localhost,127.0.0.1,::1" \
           NO_PROXY="localhost,127.0.0.1,::1"
    log "已为 Claude Desktop 设置代理: ${proxy_url}"
elif [[ "${clash_wait}" = "1" && "${clash_listening}" = "0" ]]; then
    log "Clash 混合端口 ${clash_port} 未监听，Claude 将直连"
elif [[ "${clash_listening}" = "1" && "${clash_profile_active}" = "0" ]]; then
    log "Clash 还没有启用订阅，Claude 将直连（导入订阅后重启容器即可生效）"
fi

# ------------------------------------------------------------ Claude Desktop ---
# 额外参数，例如 CLAUDE_ARGS="--no-sandbox"
app_args=()
if [[ -n "${CLAUDE_ARGS:-}" ]]; then
    read -r -a app_args <<< "${CLAUDE_ARGS}"
fi

log "启动 Claude Desktop..."
exec claude-desktop "${app_args[@]}"
