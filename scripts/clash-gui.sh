#!/usr/bin/env bash
#
# 从 Xpra 的应用菜单启动 Clash Verge 图形界面。
#
# 容器默认托管着一个无界面的 mihomo 内核；GUI 在没有 systemd 的容器里必须
# 先停掉它，才能走通「继续使用 SIDECAR」——否则 GUI 会检测到内核已被占用，
# 弹窗既关不掉也用不了。
#
set -euo pipefail

# 从菜单启动时这些变量本来就有；直接 exec 进来时补上默认值，否则 GUI 起不来。
export DISPLAY="${DISPLAY:-:100}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-claude}"
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
export GTK_A11Y=none

if pgrep -f verge-mihomo >/dev/null 2>&1; then
    echo "[clash-gui] 停止容器托管的内核，交给 GUI 管理"
    pkill -f verge-mihomo || true
    sleep 1
fi

exec clash-verge "$@"
