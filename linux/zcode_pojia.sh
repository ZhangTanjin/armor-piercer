#!/bin/sh
# TZCode 破甲工程 · Linux 部署器（POSIX sh，dash/ash/bash 通用）
# 对位 Windows 侧 TY破甲弹.exe 的 ZCode 车道：ARMOR 换弹 + PERSONA 播种 + 回滚。
# 弹体是纯 JS（resources/glm/zcode.cjs），与平台无关；变的只是壳的路径和部署器形态。
#
# 用法:
#   sh zcode_pojia.sh status                 阵地侦察（安装根/弹体状态/哈希/人格/进程）
#   sh zcode_pojia.sh deploy [--kill]        部署破甲弹（备份官方 → 换弹 → 播种人格）
#   sh zcode_pojia.sh restore                恢复官方 zcode.cjs
#   sh zcode_pojia.sh persona [file] [-f]    安装人格（默认仓库 persona.txt，已存在不覆盖）
#   sh zcode_pojia.sh hashes                 弹体/现役/备份 sha256
#
# 选项:
#   --root <dir>       安装根覆盖（AppImage --appimage-extract 解包目录等）
#   --payload <file>   弹体覆盖（默认: 脚本上级目录 armor_payload.bin）
#   --kill             部署前结束正在运行的 ZCode 进程
#
# 环境变量: ZCODE_INSTALL_ROOT  ZCODE_ARMOR_PAYLOAD  ZCODE_PERSONA_FILE
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_PAYLOAD="$SCRIPT_DIR/../armor_payload.bin"
DEFAULT_PERSONA="$SCRIPT_DIR/../persona.txt"

MARK_HOOK='ZCODE_PERSONA_FILE'
MARK_LAW='ATOMIC CONTINUATION DISPATCH'

CMD="${1:-}"; [ $# -gt 0 ] && shift
PAYLOAD="${ZCODE_ARMOR_PAYLOAD:-$DEFAULT_PAYLOAD}"
ROOT="${ZCODE_INSTALL_ROOT:-}"
KILL_FLAG=0
PERSONA_FORCE=0

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------- 参数 ----------
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    [ $# -ge 2 ] || die "--root 需要一个目录参数"; ROOT="$2"; shift 2 ;;
    --payload) [ $# -ge 2 ] || die "--payload 需要一个文件参数"; PAYLOAD="$2"; shift 2 ;;
    --kill)    KILL_FLAG=1; shift ;;
    -f)        PERSONA_FORCE=1; shift ;;
    -h|--help) usage ;;
    --*)       die "未知参数: $1（--help 看用法）" ;;
    *)         PERSONA_ARG="$1"; shift ;;
  esac
done

# ---------- 基础探针 ----------
is_fused() { # $1=file
  grep -a -q "$MARK_HOOK" "$1" 2>/dev/null && grep -a -q "$MARK_LAW" "$1"
}

file_size() { wc -c < "$1" | tr -d ' \t'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v sha256 >/dev/null 2>&1; then
    sha256 -q "$1"
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  else
    echo "n/a（系统无 sha256sum/sha256/openssl）"
  fi
}

# 正在运行的 ZCode 进程（/proc 扫描，避免依赖 pgrep）
running_pids() {
  for e in /proc/[0-9]*/exe; do
    [ -e "$e" ] || continue
    t=$(readlink "$e" 2>/dev/null) || continue
    case "$t" in */zcode|*/zcode-preview)
      p=${e%/exe}; p=${p#/proc/}; printf '%s ' "$p" ;;
    esac
  done
  printf '\n'
}

detect_root() {
  if [ -n "$ROOT" ]; then
    [ -d "$ROOT" ] || die "ZCODE_INSTALL_ROOT/--root 指定的根不存在: $ROOT"
    printf '%s\n' "$ROOT"
    return 0
  fi
  for e in /proc/[0-9]*/exe; do
    [ -e "$e" ] || continue
    t=$(readlink "$e" 2>/dev/null) || continue
    case "$t" in */zcode|*/zcode-preview)
      printf '%s\n' "$(dirname "$t")"; return 0 ;;
    esac
  done
  for c in "/opt/ZCode" "/opt/ZCode Preview" "/usr/lib/zcode" "/usr/local/lib/zcode"; do
    [ -f "$c/resources/glm/zcode.cjs" ] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

package_version() {
  if command -v dpkg >/dev/null 2>&1; then
    v=$(dpkg-query -W -f='${Version}' zcode 2>/dev/null) && [ -n "$v" ] && { printf 'deb %s' "$v"; return; }
  fi
  if command -v rpm >/dev/null 2>&1; then
    v=$(rpm -q --qf '%{VERSION}' zcode 2>/dev/null) && [ -n "$v" ] && { printf 'rpm %s' "$v"; return; }
  fi
  if command -v pacman >/dev/null 2>&1; then
    v=$(pacman -Q zcode 2>/dev/null | cut -d' ' -f2) && [ -n "$v" ] && { printf 'pacman %s' "$v"; return; }
  fi
  printf '未知（非 deb/rpm/pacman 安装）'
}

persona_path() {
  if [ -n "${ZCODE_PERSONA_FILE:-}" ]; then printf '%s\n' "$ZCODE_PERSONA_FILE"
  else printf '%s\n' "${HOME:-/root}/.zcode/persona/persona.txt"; fi
}

require_root_arg() {
  R=$(detect_root) || die "未探测到 ZCode 安装根。先装官方壳（deb/rpm/pacman/AppImage），或用 --root 指定。"
  CJS="$R/resources/glm/zcode.cjs"
  BAK="$CJS.official.bak"
  [ -f "$CJS" ] || die "布局不符：$CJS 不存在。壳版本布局可能变化，人工侦察后用 --root 指定。"
}

# ---------- status ----------
cmd_status() {
  if R=$(detect_root); then
    CJS="$R/resources/glm/zcode.cjs"
    BAK="$CJS.official.bak"
    say "安装根     : $R"
    say "包版本     : $(package_version)"
    if [ -f "$CJS" ]; then
      if is_fused "$CJS"; then state=破甲弹; else state=官方原版; fi
      say "现役弹体   : $state  $(file_size "$CJS") B  sha256=$(sha256_of "$CJS")"
    else
      say "现役弹体   : 缺失（$CJS 不存在）"
    fi
    if [ -f "$BAK" ]; then
      say "官方备份   : $BAK  $(file_size "$BAK") B  sha256=$(sha256_of "$BAK")"
    else
      say "官方备份   : 无"
    fi
    case "$R" in
      *.mount*|*/squashfs-root*) warn "疑似 AppImage 运行环境（只读 squashfs）——重启后部署即失效，看 README-Linux.md 的 AppImage 章节。";;
    esac
    [ -w "$CJS" ] || warn "对现役弹体无写权限——deploy 需要 sudo。"
  else
    say "安装根     : 未探测到（既无运行中进程，也无 /opt/ZCode 等标准目录）"
  fi
  if [ -f "$PAYLOAD" ]; then
    if is_fused "$PAYLOAD"; then pstate=融合弹; else pstate=裸弹（未融合/损坏）; fi
    say "弹药库弹体 : $pstate  $PAYLOAD"
    say "             $(file_size "$PAYLOAD") B  sha256=$(sha256_of "$PAYLOAD")"
  else
    say "弹药库弹体 : 缺失（$PAYLOAD）"
  fi
  PP=$(persona_path)
  if [ -f "$PP" ]; then
    say "人格文件   : $PP  $(file_size "$PP") B"
  else
    say "人格文件   : 缺失（$PP）——破甲版将回退官方装配"
  fi
  [ -n "${ZCODE_PERSONA_FILE:-}" ] && say "人格覆盖   : ZCODE_PERSONA_FILE 已设置"
  PIDS=$(running_pids)
  [ -n "$PIDS" ] && warn "ZCode 正在运行（pid: $PIDS）——部署前先完全退出，或 deploy --kill"
  return 0
}

# ---------- deploy ----------
cmd_deploy() {
  require_root_arg
  [ -f "$PAYLOAD" ] || die "弹体不存在: $PAYLOAD（--payload 指定，或把 armor_payload.bin 放到脚本上级目录）"
  is_fused "$PAYLOAD" || die "弹体未融合或缺标记（$MARK_HOOK / $MARK_LAW），拒绝部署裸弹。"

  case "$R" in
    *.mount*|*/squashfs-root*)
      die "AppImage 运行环境只读。先 --appimage-extract，再用 --root 指向解包目录（README-Linux.md）。";;
  esac
  [ -w "$CJS" ] || die "无写权限: $CJS —— 用 sudo 重跑本命令。"

  PIDS=$(running_pids)
  if [ -n "$PIDS" ]; then
    if [ "$KILL_FLAG" = 1 ]; then
      pkill -x zcode 2>/dev/null || true
      pkill -x zcode-preview 2>/dev/null || true
      sleep 1
      say "[i] 已结束运行中的 ZCode（pid: $PIDS）"
    else
      die "ZCode 正在运行（pid: $PIDS）。先完全退出目标应用，或加 --kill。"
    fi
  fi

  if is_fused "$CJS"; then
    [ -f "$BAK" ] || die "现役已是破甲弹但无官方备份（$BAK 缺失）。先 restore 或重装官方壳，再部署。"
    say "[i] 现役为破甲弹 → 洗弹重部署（官方备份保持不动）"
  else
    cp -f "$CJS" "$BAK"
    cmp -s "$CJS" "$BAK" || die "备份自校验失败（cmp 不一致），中止。"
    say "[+] 官方原版已备份 → $(basename "$BAK")  sha256=$(sha256_of "$BAK")"
  fi

  cp -f "$PAYLOAD" "$CJS"
  cmp -s "$PAYLOAD" "$CJS" || die "部署自校验失败（弹体与现役不一致），中止——官方备份仍在 $BAK。"
  say "[+] 破甲弹已上膛 → $CJS  sha256=$(sha256_of "$CJS")"

  PP=$(persona_path)
  if [ ! -f "$PP" ] && [ -f "$DEFAULT_PERSONA" ]; then
    mkdir -p "$(dirname "$PP")"
    cp -f "$DEFAULT_PERSONA" "$PP"
    say "[+] 人格已播种 → $PP"
  else
    say "[i] 人格保持现状（$PP）"
  fi

  say ""
  say "完成。启动 ZCode（应用菜单或 $R/zcode）→ 新对话生效。"
  say "回滚: sh zcode_pojia.sh restore"
}

# ---------- restore ----------
cmd_restore() {
  require_root_arg
  [ -f "$BAK" ] || die "未找到官方备份（$BAK）——无备份不回滚，重装官方安装包兜底。"
  [ -w "$CJS" ] || die "无写权限: $CJS —— 用 sudo 重跑本命令。"
  PIDS=$(running_pids)
  if [ -n "$PIDS" ] && [ "$KILL_FLAG" = 1 ]; then
    pkill -x zcode 2>/dev/null || true
    pkill -x zcode-preview 2>/dev/null || true
    sleep 1
  elif [ -n "$PIDS" ]; then
    die "ZCode 正在运行（pid: $PIDS）。先完全退出，或加 --kill。"
  fi
  cp -f "$BAK" "$CJS"
  cmp -s "$BAK" "$CJS" || die "恢复自校验失败。"
  say "[+] 已恢复官方 → $CJS  sha256=$(sha256_of "$CJS")"
  say "[i] 官方备份保留在 $BAK（下次部署直接复用）"
  say "完成。重启 ZCode 生效。"
}

# ---------- persona ----------
cmd_persona() {
  PP=$(persona_path)
  SRC="$DEFAULT_PERSONA"
  [ -n "${PERSONA_ARG:-}" ] && SRC="$PERSONA_ARG"
  [ -f "$SRC" ] || die "人格源文件不存在: $SRC"
  if [ -f "$PP" ] && [ "$PERSONA_FORCE" = 0 ]; then
    say "[i] 人格已存在，未覆盖: $PP（-f 强制覆盖）"
    say "---- 前 5 行 ----"
    head -n 5 "$PP"
    return 0
  fi
  mkdir -p "$(dirname "$PP")"
  cp -f "$SRC" "$PP"
  say "[+] 人格已安装 → $PP  sha256=$(sha256_of "$PP")"
  say "重启 ZCode，新对话生效。"
}

# ---------- hashes ----------
cmd_hashes() {
  require_root_arg
  say "payload : $( [ -f "$PAYLOAD" ] && sha256_of "$PAYLOAD" || echo '缺失' )  $PAYLOAD"
  say "current : $(sha256_of "$CJS")  $CJS"
  say "backup  : $( [ -f "$BAK" ] && sha256_of "$BAK" || echo '缺失' )  $BAK"
}

# ---------- 入口 ----------
case "$CMD" in
  status)  cmd_status ;;
  deploy)  cmd_deploy ;;
  restore) cmd_restore ;;
  hashes)  cmd_hashes ;;
  persona) cmd_persona ;;
  ""|-h|--help|help) usage ;;
  *) die "未知命令: $CMD（status/deploy/restore/persona/hashes）" ;;
esac
