#!/usr/bin/env bash
#
# 只重启会话里的 Claude Desktop，不动 Xpra、Clash 窗口和代理内核。
#
# 会话脚本用循环守护 Claude（见 start-session.sh），所以这里杀掉进程后
# 3 秒内会自动拉起，浏览器/原生客户端的连接保持不断。
#
set -euo pipefail

killed=0

# Electron 主进程。官方包在 /usr/lib/claude-desktop/，
# 社区重打包版在 /usr/lib/claude-desktop-unofficial/，用前缀一次覆盖。
if pkill -f '/usr/lib/claude-desktop' 2>/dev/null; then
    killed=1
fi

# 启动器（/usr/bin/<包名> 以及我们建的 /usr/local/bin/claude-desktop 入口）
for pattern in '/usr/bin/claude-desktop' '/usr/local/bin/claude-desktop'; do
    if pkill -f "${pattern}" 2>/dev/null; then
        killed=1
    fi
done

if [[ "${killed}" = "0" ]]; then
    echo "没有找到正在运行的 Claude Desktop（可能正在重启中）"
else
    echo "已结束 Claude Desktop，3 秒内会自动重启"
fi
