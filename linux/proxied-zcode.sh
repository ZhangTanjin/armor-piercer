#!/bin/sh
# ZCode 抓包发射器（Linux 版，对位 Windows 侧 launch-proxied.bat）
# 代理 + CA 注入启动官方壳，配合 mitmdump 捕获官方请求三要素
# （目标 URL × 鉴权头形态 × 签名头有无）。
#
# 前置: pip install mitmproxy && mitmdump   （首次运行生成 ~/.mitmproxy/mitmproxy-ca-cert.pem）
# 用法: sh proxied-zcode.sh [zcode参数...]
#       MITM_PROXY=http://127.0.0.1:8888 sh proxied-zcode.sh
set -eu

MITM="${MITM_PROXY:-http://127.0.0.1:8888}"
CA="${MITM_CA:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}"

export HTTPS_PROXY="$MITM"
export HTTP_PROXY="$MITM"
export NO_PROXY="localhost,127.0.0.1"

if [ -f "$CA" ]; then
  export NODE_EXTRA_CA_CERTS="$CA"
else
  printf '[!] CA 不存在: %s —— 先跑一次 mitmdump 生成，或 MITM_CA= 指定路径\n' "$CA" >&2
fi

if command -v zcode >/dev/null 2>&1; then
  BIN=zcode
elif [ -x "/opt/ZCode/zcode" ]; then
  BIN="/opt/ZCode/zcode"
elif [ -x "/opt/ZCode Preview/zcode-preview" ]; then
  BIN="/opt/ZCode Preview/zcode-preview"
else
  printf '[-] 未找到 zcode 可执行（PATH、/opt/ZCode/zcode、Preview 均未命中）\n' >&2
  exit 1
fi

printf '[i] 代理=%s  CA=%s  启动=%s\n' "$MITM" "$CA" "$BIN"
exec "$BIN" "$@"
