#!/usr/bin/env bash
#
# 容器入口：准备运行目录、生成/读取访问密码，然后前台启动 Xpra。
#
# 对外只暴露一个端口：Xpra 的 TCP 端口同时提供 HTML5 客户端（--html=on）。
#
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }

export HOME="${HOME:-/home/claude}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-claude}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
export XPRA_DISPLAY="${XPRA_DISPLAY:-:100}"
export XPRA_PORT="${XPRA_PORT:-14500}"
export XPRA_SOCKET_DIR="${XPRA_SOCKET_DIR:-/tmp/xpra}"

mkdir -p \
    "${XDG_RUNTIME_DIR}" \
    "${XDG_CONFIG_HOME}/Claude" \
    "${XDG_DATA_HOME}" \
    "${XDG_CACHE_HOME}" \
    "${XPRA_SOCKET_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}" "${XPRA_SOCKET_DIR}"

# ---------------------------------------------------------------- 访问密码 ---
# 优先级：XPRA_PASSWORD 环境变量 > 持久化的密码文件 > 随机生成并持久化。
PASSWORD_FILE="${XDG_CONFIG_HOME}/claude-xpra/password"
mkdir -p "$(dirname "${PASSWORD_FILE}")"

if [[ -n "${XPRA_PASSWORD:-}" ]]; then
    printf '%s' "${XPRA_PASSWORD}" > "${PASSWORD_FILE}"
elif [[ ! -s "${PASSWORD_FILE}" ]]; then
    XPRA_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)"
    printf '%s' "${XPRA_PASSWORD}" > "${PASSWORD_FILE}"
    log "已生成随机访问密码并保存到 ${PASSWORD_FILE}"
fi

if [[ -z "${XPRA_PASSWORD:-}" ]]; then
    XPRA_PASSWORD="$(cat "${PASSWORD_FILE}")"
fi
chmod 0600 "${PASSWORD_FILE}"

log "HTML5 访问地址 : http://<宿主机IP>:${XPRA_PORT}/"
log "登录用户名     : 任意（例如 claude）"
log "登录密码       : ${XPRA_PASSWORD}"

# --------------------------------------------------------------- Xpra 参数 ---
# 注意：`--tcp-auth=password` 并不会去读 --password-file，它要求用
# password:value=<明文> 直接把密码写在参数里（会出现在 ps 中）。
# 这里改用 file 认证模块，它才是「密码文件里只放一个密码」的语义。
xpra_auth="${XPRA_TCP_AUTH:-file:filename=${PASSWORD_FILE}}"

xpra_args=(
    "start" "${XPRA_DISPLAY}"
    "--bind-tcp=0.0.0.0:${XPRA_PORT}"
    "--html=${XPRA_HTML:-on}"
    "--tcp-auth=${xpra_auth}"
    "--password-file=${PASSWORD_FILE}"
    "--socket-dir=${XPRA_SOCKET_DIR}"
    "--start-child=/usr/local/bin/start-session.sh"
    "--exit-with-children=yes"
    "--systemd-run=no"
    "--mdns=no"
    "--daemon=no"
)

# 可选：启用 TLS（浏览器将使用 https://）
if [[ -n "${XPRA_SSL_CERT:-}" && -n "${XPRA_SSL_KEY:-}" ]]; then
    xpra_args+=(
        "--ssl-cert=${XPRA_SSL_CERT}"
        "--ssl-key=${XPRA_SSL_KEY}"
    )
    log "已启用 TLS：${XPRA_SSL_CERT}"
fi

# 可选：追加任意 Xpra 服务端参数
if [[ -n "${XPRA_EXTRA_ARGS:-}" ]]; then
    read -r -a extra_args <<< "${XPRA_EXTRA_ARGS}"
    xpra_args+=("${extra_args[@]}")
fi

# Electron / Chromium 需要一个 D-Bus session bus
if command -v dbus-run-session >/dev/null 2>&1; then
    exec dbus-run-session -- xpra "${xpra_args[@]}"
else
    log "未找到 dbus-run-session，直接启动 Xpra"
    exec xpra "${xpra_args[@]}"
fi
