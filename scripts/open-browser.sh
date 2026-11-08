#!/usr/bin/env bash
#
# xdg-open / Electron shell.openExternal 的浏览器入口。
# 按可用性依次尝试，找不到就明确报错，避免登录流程静默失败。
#
set -euo pipefail

for candidate in epiphany epiphany-browser chromium google-chrome firefox; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        exec "${candidate}" "$@"
    fi
done

printf '[browser] 镜像内没有可用浏览器，无法打开: %s\n' "$*" >&2
printf '[browser] 请重新构建并去掉 INSTALL_BROWSER=false，或在宿主机完成登录后挂载 ~/.config/Claude\n' >&2
exit 1
