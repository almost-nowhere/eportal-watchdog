#!/bin/sh
# 锐捷 ePortal 校园网看门狗的安装脚本。在 OpenWrt 路由器上以 root 运行。
#
#   sh install.sh              安装；已经装过则只更新脚本，保留原来的账号配置
#   sh install.sh uninstall    卸载
#
# 取文件的方式：脚本所在目录里有 campus-watchdog.uc 就用本地的（适合把整个仓库
# 拷到路由器上再装）；没有就从 GitHub 下载。

set -e

BASE_URL="https://raw.githubusercontent.com/almost-nowhere/eportal-watchdog/main"
PROG=/usr/bin/campus-watchdog.uc
INIT=/etc/init.d/campus-watchdog
CONF=/etc/config/campus_network
MODULES="fs uci ubus log"          # 看门狗用到的 ucode 模块

die() {
    echo "错误：$*" >&2
    exit 1
}

[ "$(id -u)" = "0" ] || die "需要以 root 运行"
[ -f /etc/openwrt_release ] || die "这不是 OpenWrt 系统"

if [ "$1" = "uninstall" ]; then
    [ -x "$INIT" ] && { "$INIT" stop || true; "$INIT" disable || true; }
    rm -f "$PROG" "$INIT"
    echo "已卸载。"
    [ -f "$CONF" ] && echo "配置文件 $CONF 还在（里面有明文密码），不再需要请手动删除：rm $CONF"
    exit 0
fi

# ---- 依赖：ucode 解释器和几个模块，缺了就装 ----
missing=""
command -v ucode >/dev/null || missing="ucode"
for m in $MODULES; do
    [ -e "/usr/lib/ucode/$m.so" ] || missing="$missing ucode-mod-$m"
done
if [ -n "$missing" ]; then
    echo "缺少软件包：$missing，正在安装（需要路由器当前能上网）……"
    if command -v apk >/dev/null; then
        apk update && apk add $missing
    elif command -v opkg >/dev/null; then
        opkg update && opkg install $missing
    else
        die "找不到 apk 或 opkg，请手动安装：$missing"
    fi
fi

# ---- 取两个文件，先放到临时位置，都拿到了再替换 ----
here="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
tmp="/tmp/campus-watchdog-install.$$"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

fetch() {
    if [ -f "$here/campus-watchdog.uc" ]; then
        cp "$here/$1" "$tmp/$1"
    else
        wget -q -O "$tmp/$1" "$BASE_URL/$1" || die "下载 $1 失败。可以改为把整个仓库拷到路由器上再运行本脚本"
    fi
    [ -s "$tmp/$1" ] || die "$1 是空文件"
}
fetch campus-watchdog.uc
fetch campus-watchdog.init

[ -x "$INIT" ] && "$INIT" stop || true
cp "$tmp/campus-watchdog.uc" "$PROG"
cp "$tmp/campus-watchdog.init" "$INIT"
chmod 755 "$PROG" "$INIT"

# ---- 配置：只在还没有账号时才问 ----
if [ ! -f "$CONF" ]; then
    touch "$CONF"
    uci set campus_network.settings=login
fi
chmod 600 "$CONF"

if [ -z "$(uci -q get campus_network.settings.username)" ]; then
    printf "校园网账号："
    read -r user
    printf "校园网密码（输入时不显示）："
    stty -echo 2>/dev/null || true
    read -r pass
    stty echo 2>/dev/null || true
    echo
    printf "门户地址（不知道就直接回车，会自动识别）："
    read -r portal

    [ -n "$user" ] && [ -n "$pass" ] || die "账号和密码不能为空。重新运行本脚本即可"
    uci set campus_network.settings.username="$user"
    uci set campus_network.settings.password="$pass"

    portal="${portal#http://}"
    portal="${portal%%/*}"
    if [ -n "$portal" ]; then
        case "$portal" in
            *[!A-Za-z0-9.:-]*) die "门户地址只能是 IP 或域名，例如 192.0.2.1" ;;
        esac
        uci set campus_network.settings.portal_server="$portal"
    fi
fi
uci set campus_network.settings.enabled='1'
uci commit campus_network

"$INIT" enable
"$INIT" start

echo
echo "安装完成，看门狗已启动。"
radio="$(uci -q get campus_network.settings.radio_5g || true)"
[ -n "$radio" ] || radio="$(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.band='5g'$/\1/p" | head -n 1)"
if [ "$(uci -q get campus_network.settings.night_wifi_off)" = "0" ]; then
    echo "夜间断网时不关 Wi-Fi。"
elif [ -n "$radio" ]; then
    echo "夜间断网时会关闭的 5G 射频：$radio（2.4G 不受影响）"
else
    echo "没有找到 5G 射频，夜间断网时只休眠、不关 Wi-Fi。"
fi
echo "看日志：logread -e campus-watchdog"
echo "改配置：编辑 $CONF 后执行 service campus-watchdog restart"
