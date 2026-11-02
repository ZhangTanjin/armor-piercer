#!/bin/sh
# TZcode 破甲工程 · Linux Qoder app.asar 附件限额补丁器（POSIX sh + node）v1
# 目标: <root>/app.asar 主进程常量  单文件 100*1024*1024 → 999*1024*1024（953MiB）
#                              单次 200 → 999 个文件
# 锚点为结构匹配（=200,=10,=100*1024*1024 三元组相邻），免疫混淆器改名；等长替换，
# asar 无校验和、索引零扰动。全程自校验：命中唯一、长度不变、恰好 6 字节差异。
#
# 用法:
#   sh asar_pojia.sh status               侦察（现役状态/备份/锚点）
#   sh asar_pojia.sh build [out]          造弹+自校验（不动系统，默认 /tmp）
#   sh asar_pojia.sh deploy [--kill]      备份官方 → 上弹（/usr/lib 需 sudo）
#   sh asar_pojia.sh restore [--kill]     回滚最新官方备份
# 选项:
#   --asar <file>   目标 app.asar 路径覆盖（QODER_ASAR 同效）
#   --kill          deploy/restore 前结束运行中的 Qoder
# 环境变量: QODER_ASAR  NODE_BIN
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
NODE_BIN="${NODE_BIN:-$(command -v node || echo /usr/bin/node)}"
ASAR="${QODER_ASAR:-}"
KILL_FLAG=0
BUILD_OUT=""

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --asar)  [ $# -ge 2 ] || die "--asar 需要一个文件参数"; ASAR="$2"; shift 2 ;;
    --kill)  KILL_FLAG=1; shift ;;
    -h|--help) usage ;;
    --*)     die "未知参数: $1（--help 看用法）" ;;
    *)       [ "$CMD" = build ] && [ -z "$BUILD_OUT" ] && { BUILD_OUT="$1"; shift; } || die "多余参数: $1" ;;
  esac
done

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
is_patched() { grep -a -q -E '[A-Za-z_$][A-Za-z0-9_$]*=999,[A-Za-z_$][A-Za-z0-9_$]*=10,[A-Za-z_$][A-Za-z0-9_$]*=999\*1024\*1024' "$1" 2>/dev/null; }
is_official(){ grep -a -q -E '[A-Za-z_$][A-Za-z0-9_$]*=200,[A-Za-z_$][A-Za-z0-9_$]*=10,[A-Za-z_$][A-Za-z0-9_$]*=100\*1024\*1024' "$1" 2>/dev/null; }

running_qoder_pids() {
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in *qoder-cn*) printf '%s ' "${d#/proc/}";; esac
  done
  printf '\n'
}
kill_qoder() {
  pkill -x qoder-cn 2>/dev/null || true
  pkill -f 'qoder-cn/qoder-cn[.]js' 2>/dev/null || true
  sleep 1
}

detect_asar() {
  if [ -n "$ASAR" ]; then
    [ -f "$ASAR" ] || die "--asar/QODER_ASAR 指定的文件不存在: $ASAR"
    printf '%s\n' "$ASAR"; return 0
  fi
  for f in /usr/lib/qoder-cn/app.asar /opt/qoder-cn/app.asar "/opt/Qoder CN/app.asar" /opt/Qoder/app.asar; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
require_asar() { detect_asar || die "未探测到 app.asar。用 --asar 指定路径。"; }

qoder_version() {
  if command -v pacman >/dev/null 2>&1; then
    v=$(pacman -Q qoder-cn-bin 2>/dev/null | awk '{print $2}') || v=""
    [ -n "$v" ] && { printf '%s\n' "${v%%-*}"; return; }
  fi
  echo unknown
}

# ---------- node 手术引擎 ----------
write_engine() { # $1=js $2=输入asar $3=输出
cat > "$1" <<'ENGINE_EOF'
const fs = require('node:fs');
const [,, src, out] = process.argv;
const buf = fs.readFileSync(src);
const s = buf.toString('latin1');
const WIN_RE = /([A-Za-z_$][A-Za-z0-9_$]*)=200,([A-Za-z_$][A-Za-z0-9_$]*)=10,([A-Za-z_$][A-Za-z0-9_$]*)=100\*1024\*1024/;
// indexOf 预筛 + 窗口正则验证（避免 184MB 全串正则扫描）
const hits = [];
let p = 0;
while ((p = s.indexOf('=200,', p)) >= 0) {
  const w = Math.max(0, p - 64);
  const m = s.slice(w, p + 160).match(WIN_RE);
  if (m && !hits.some(h => h.start === w + m.index)) hits.push({ start: w + m.index, m });
  p += 5;
}
if (hits.length !== 1) { console.error('结构锚点命中 ' + hits.length + ' 次（需恰好 1）——版本布局可能已变，中止'); process.exit(1); }
const hit = hits[0], m = hit.m;
const NEW = m[1] + '=999,' + m[2] + '=10,' + m[3] + '=999*1024*1024';
console.log('锚点: ' + m[0] + '  →  ' + NEW);
Buffer.from(NEW, 'latin1').copy(buf, hit.start);
fs.writeFileSync(out, buf);
// ---- 自校验 ----
const back = fs.readFileSync(out);
if (back.length !== buf.length) { console.error('长度不一致'); process.exit(1); }
const t = back.toString('latin1');
if (!t.includes(NEW)) { console.error('补丁锚点缺失'); process.exit(1); }
if (t.slice(Math.max(0, hit.start - 64), hit.start + NEW.length + 64).match(WIN_RE)) { console.error('官方锚点仍存在'); process.exit(1); }
let odiff = 0, first = -1, last = -1;
const orig = fs.readFileSync(src);
for (let i = 0; i < back.length; i++) if (back[i] !== orig[i]) { odiff++; if (first < 0) first = i; last = i; }
if (odiff !== 6) { console.error('差异字节数 ' + odiff + '（需恰好 6）'); process.exit(1); }
console.log('OK bytes=' + back.length + '  diff=' + odiff + '  区间=' + first + '-' + last);
ENGINE_EOF
}

run_engine() { # $1=src $2=out
  TMPJS=$(mktemp /tmp/asar_engine.XXXXXX.cjs)
  write_engine "$TMPJS"
  "$NODE_BIN" "$TMPJS" "$1" "$2" || { rm -f "$TMPJS"; die "造弹失败（见上方引擎输出）"; }
  rm -f "$TMPJS"
}

cmd_status() {
  A=$(require_asar)
  VER=$(qoder_version)
  say "app.asar    : $A"
  say "Qoder 版本   : $VER"
  if   is_patched "$A";  then state='限额弹（999 文件 / 953MiB）';
  elif is_official "$A"; then state='官方原版（200 文件 / 100MiB）';
  else state='未知布局（锚点均未命中，需人工侦察）'; fi
  say "现役状态     : $state  $(wc -c < "$A" | tr -d ' \t') B  sha256=$(sha256_of "$A")"
  for b in "$A".official.bak-*; do [ -f "$b" ] && say "官方备份     : $(basename "$b")  $(wc -c < "$b" | tr -d ' \t') B  sha256=$(sha256_of "$b")"; done
  [ -w "$A" ] || warn "无写权限——deploy 需要 sudo。"
  PIDS=$(running_qoder_pids); [ -n "$PIDS" ] && warn "Qoder 正在运行（pid: $PIDS）——deploy 前先退出，或 --kill"
}

cmd_build() {
  A=$(require_asar)
  is_patched "$A" && die "现役已是限额弹（无需造）。要重打请对官方备份操作。"
  [ -n "$BUILD_OUT" ] || BUILD_OUT="/tmp/app_asar_patched_$(qoder_version "$A").asar"
  run_engine "$A" "$BUILD_OUT"
  say "[+] 限额弹已造出并自校验通过 → $BUILD_OUT  $(wc -c < "$BUILD_OUT" | tr -d ' \t') B  sha256=$(sha256_of "$BUILD_OUT")"
}

cmd_deploy() {
  A=$(require_asar)
  VER=$(qoder_version)
  [ -w "$A" ] || die "无写权限: $A —— 用 sudo 重跑本命令。"
  PIDS=$(running_qoder_pids)
  if [ -n "$PIDS" ]; then
    [ "$KILL_FLAG" = 1 ] || die "Qoder 正在运行（pid: $PIDS）。先完全退出，或加 --kill。"
    kill_qoder; say "[i] 已结束运行中的 Qoder（pid: $PIDS）"
  fi
  BAK="$A.official.bak-$VER"
  if is_patched "$A"; then
    [ -f "$BAK" ] || die "现役已是限额弹但无官方备份（$BAK 缺失）。先 restore 或重装官方包。"
    say "[i] 现役为限额弹 → 从官方备份重打（备份保持不动）"
    SRC="$BAK"
  else
    cp -f "$A" "$BAK"
    cmp -s "$A" "$BAK" || die "备份自校验失败，中止。"
    say "[+] 官方原版已备份 → $(basename "$BAK")  sha256=$(sha256_of "$BAK")"
    SRC="$A"
  fi
  OUT=$(mktemp /tmp/app_asar_patched.XXXXXX.asar)
  trap 'rm -f "$OUT"' EXIT
  run_engine "$SRC" "$OUT"
  cp -f "$OUT" "$A"
  cmp -s "$OUT" "$A" || die "部署自校验失败——官方备份仍在 $BAK。"
  say "[+] 限额弹已上膛 → $A  sha256=$(sha256_of "$A")"
  say "完成。启动 Qoder 生效。回滚: sh asar_pojia.sh restore"
}

cmd_restore() {
  A=$(require_asar)
  BAK=$(ls "$A".official.bak-* 2>/dev/null | sort -V | tail -1) || true
  [ -n "$BAK" ] && [ -f "$BAK" ] || die "未找到官方备份（$A.official.bak-*）。"
  [ -w "$A" ] || die "无写权限: $A —— 用 sudo 重跑本命令。"
  PIDS=$(running_qoder_pids)
  if [ -n "$PIDS" ]; then
    [ "$KILL_FLAG" = 1 ] || die "Qoder 正在运行（pid: $PIDS）。先完全退出，或加 --kill。"
    kill_qoder
  fi
  cp -f "$BAK" "$A"
  cmp -s "$BAK" "$A" || die "恢复自校验失败。"
  say "[+] 官方原版已恢复 ← $(basename "$BAK")  sha256=$(sha256_of "$A")"
}

case "$CMD" in
  status)  cmd_status ;;
  build)   cmd_build ;;
  deploy)  cmd_deploy ;;
  restore) cmd_restore ;;
  ""|-h|--help) usage ;;
  *) die "未知子命令: $CMD（--help 看用法）" ;;
esac
