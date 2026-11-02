#!/bin/sh
# TZcode 破甲工程 · Linux Qoder 部署器（POSIX sh + node 手术引擎）v2
# 对位 Windows 侧 patch_qoder_all.ps1 / TY破甲弹.exe 内置引擎：
#   密钥嗅探 → 身份钩注入 → 十层内容匹配换弹 → 自校验 + 语法闸 → 备份部署
# v2 修复:
#   - 身份钩模板正则补回尾部反引号（v1 丢失闭合反引号导致模板串不闭合、worker 语法错误）
#   - build/deploy 增加 node --check 语法闸：弹体解析不过禁止出弹
#   - 现役为装甲时，洗弹改从官方备份重建（不从已装甲弹体叠加手术）
#
# 用法:
#   sh qoder_pojia.sh status              阵地侦察
#   sh qoder_pojia.sh build [out.mjs]     造弹+自校验（不动系统；默认 /tmp）
#   sh qoder_pojia.sh deploy [--kill]     备份官方 → 换弹 → 播种人格（/usr/lib 下需 sudo）
#   sh qoder_pojia.sh restore [--kill]    恢复最新官方备份
#   sh qoder_pojia.sh persona [file] [-f] 安装人格（已存在不覆盖）
#   sh qoder_pojia.sh hashes              哈希账本
#
# 选项:
#   --worker <file>   弹体路径覆盖（QODER_WORKER 同效）
#   --kill            deploy/restore 前结束运行中的 Qoder
# 环境变量: QODER_WORKER  NODE_BIN
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_PERSONA="$SCRIPT_DIR/../qoder_persona.txt"
[ -f "$DEFAULT_PERSONA" ] || DEFAULT_PERSONA="$(getent passwd "$(id -un)" | cut -d: -6 2>/dev/null || echo "$HOME")/.qoder-cn/persona.txt"
FORK="$SCRIPT_DIR/../qoder-fork"
LAYER_FILES="armor-notice.txt layer-delivering.txt layer-classifier.txt layer-rules.txt layer-classifier2.txt layer-judge2.txt layer-rules2.txt layer-rules3.txt layer-prefs.txt layer-automode.txt layer-monitor.txt layer-pass2.txt"
NODE_BIN="${NODE_BIN:-$(command -v node || echo /usr/bin/node)}"
WORKER="${QODER_WORKER:-}"
KILL_FLAG=0
PERSONA_FORCE=0
PERSONA_ARG=""
BUILD_OUT=""

say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[-] %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------- 参数 ----------
CMD="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --worker)  [ $# -ge 2 ] || die "--worker 需要一个文件参数"; WORKER="$2"; shift 2 ;;
    --kill)    KILL_FLAG=1; shift ;;
    -f)        PERSONA_FORCE=1; shift ;;
    -h|--help) usage ;;
    --*)       die "未知参数: $1（--help 看用法）" ;;
    *)         if [ -z "$BUILD_OUT" ] && [ "$CMD" = build ]; then BUILD_OUT="$1";
               elif [ -z "$PERSONA_ARG" ] && [ "$CMD" = persona ]; then PERSONA_ARG="$1";
               else die "多余参数: $1"; fi; shift ;;
  esac
done

# ---------- 基础探针 ----------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  else echo "n/a"; fi
}

is_armored() { grep -a -q '/.qoder-cn/persona.txt' "$1" 2>/dev/null; }

running_qoder_pids() {
  for d in /proc/[0-9]*; do
    c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in *qoder-cn*) printf '%s ' "${d#/proc/}";; esac
  done
  printf '\n'
}

kill_qoder() {
  pkill -x qoder-cn 2>/dev/null || true
  pkill -f 'qoder-cn/qoder-cn\.js' 2>/dev/null || true
  sleep 1
}

detect_worker() {
  if [ -n "$WORKER" ]; then
    [ -f "$WORKER" ] || die "--worker/QODER_WORKER 指定的弹体不存在: $WORKER"
    printf '%s\n' "$WORKER"; return 0
  fi
  for root in /usr/lib/qoder-cn /usr/lib/qoder "/opt/Qoder CN" /opt/qoder-cn /opt/Qoder; do
    if [ -d "$root/.qoder-versions" ]; then
      for v in $(ls "$root/.qoder-versions" 2>/dev/null | sort -rV); do
        f="$root/.qoder-versions/$v/app.asar.unpacked/node_modules/@qoder-ai/qoder-cn-agent-sdk/dist/_worker/qoder-worker-runtime.obf.mjs"
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
      done
    fi
    for f in "$root/app.asar.unpacked/node_modules/@qoder-ai/qoder-cn-agent-sdk/dist/_worker/qoder-worker-runtime.obf.mjs" \
             "$root/resources/app.asar.unpacked/node_modules/@qoder-ai/qoder-cn-agent-sdk/dist/_worker/qoder-worker-runtime.obf.mjs"; do
      [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
  done
  return 1
}

require_worker() {
  detect_worker || die "未探测到 Qoder worker 弹体。先装 Qoder CN（deb/pacman），或用 --worker 指定 qoder-worker-runtime.obf.mjs 路径。"
}

qoder_version() {
  case "$1" in
    */.qoder-versions/*) printf '%s\n' "$1" | sed -E 's#.*/\.qoder-versions/([^/]+)/.*#\1#'; return ;;
  esac
  if command -v pacman >/dev/null 2>&1; then
    v=$(pacman -Q qoder-cn-bin 2>/dev/null | awk '{print $2}') || v=""
    [ -n "$v" ] && { printf '%s\n' "${v%%-*}"; return; }
    v=$(pacman -Q qoder 2>/dev/null | awk '{print $2}') || v=""
    [ -n "$v" ] && { printf '%s\n' "${v%%-*}"; return; }
  fi
  echo unknown
}

real_home() {
  getent passwd "${SUDO_USER:-$(id -un)}" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}"
}

persona_path() { printf '%s/.qoder-cn/persona.txt\n' "$(real_home)"; }

require_ammo() {
  [ -x "$NODE_BIN" ] || die "缺 node 引擎: $NODE_BIN（NODE_BIN 可覆盖）"
  for f in $LAYER_FILES; do [ -f "$FORK/$f" ] || die "弹药层缺失: $FORK/$f"; done
}

# ---------- node 手术引擎（对位 patch_qoder_all.ps1；v2 修正模板身份正则闭合反引号） ----------
write_engine() { # $1=输出 js 路径
cat > "$1" <<'ENGINE_EOF'
const fs = require('node:fs');
const [,, worker, out, fork] = process.argv;
let text = fs.readFileSync(worker, 'utf8');

// ---- detect the XOR key from the header decoder（按结构识别，免疫 _$d/_$d1 等标识符改名）----
const head = text.slice(0, 400);
const mk = head.match(/const ([A-Za-z_$][A-Za-z0-9_$]*)=\(s,k="([^"]+)"\)=>\{const [A-Za-z_$][A-Za-z0-9_$]*=Buffer\.from\(s,"base64"\)/);
if (!mk) { console.error('decoder signature not found'); process.exit(1); }
const DEC = mk[1];
const key = Buffer.from(mk[2], 'ascii');
console.log('decoder: ' + DEC + '  key: ' + mk[2]);
const decode = s => { const b = Buffer.from(s, 'base64'); for (let i = 0; i < b.length; i++) b[i] ^= key[i % key.length]; return b.toString('utf8'); };
const encode = s => { const b = Buffer.from(s, 'utf8'); for (let i = 0; i < b.length; i++) b[i] ^= key[i % key.length]; return b.toString('base64'); };

// ---- identity hook (idempotent) ----
const iife = '(()=>{try{const __p=require("node:fs").readFileSync(require("node:os").homedir()+"/.qoder-cn/persona.txt","utf8").trim();if(__p)return __p}catch(__e){}return ';
if (!text.includes('/.qoder-cn/persona.txt')) {
  const m1 = text.match(/([A-Za-z_$][\w$]*)="You are a Qoder agent\."/);
  if (!m1) { console.error('identity constant (You are a Qoder agent.) not found'); process.exit(1); }
  text = text.slice(0, m1.index) + m1[1] + '=' + iife + '"You are a Qoder agent."})()' + text.slice(m1.index + m1[0].length);
  // template identity: X=`You are ${Y}.`  (正则必须吃掉闭合反引号，否则截断模板)
  const m2 = text.match(/([A-Za-z_$][\w$]*)=`You are \$\{([A-Za-z_$][\w$]*)\}\.`/);
  if (m2) {
    const keep = m2[0].slice(m2[0].indexOf('=') + 1);
    text = text.slice(0, m2.index) + m2[1] + '=' + iife + keep + '})()' + text.slice(m2.index + m2[0].length);
    console.log('identity: both constants hooked');
  } else {
    console.log('identity: primary hooked (template constant not found)');
  }
} else {
  console.log('identity: hook already present');
}

// ---- collect blobs and patch by content predicate ----
const specs = [
  ['notice',      'armor-notice.txt',      d => d.startsWith('IMPORTANT:')],
  ['delivering',  'layer-delivering.txt',  d => d.startsWith('# Delivering work')],
  ['classifier',  'layer-classifier.txt',  d => d.startsWith('Judge whether the pending action')],
  ['rules',       'layer-rules.txt',       d => d.includes('CHECK: Is this routine')],
  ['judge2',      'layer-judge2.txt',      d => d.startsWith('Judge only the pending action')],
  ['rules2',      'layer-rules2.txt',      d => d.startsWith('\nCHECK: Does the action respect')],
  ['rules3',      'layer-rules3.txt',      d => d.startsWith('\nCHECK: Is the action free of non-waivable')],
  ['automode',    'layer-automode.txt',    d => d.includes('## Auto Mode Active')],
  // 代际层：0.4.x 与 0.5.x 各自命中，未命中跳过（opt 标志）
  ['classifier2', 'layer-classifier2.txt', d => d.startsWith('You are a security classifier'), true],
  ['prefs',       'layer-prefs.txt',       d => d.includes('DO NOT override the core safety'), true],
  ['monitor',     'layer-monitor.txt',     d => d.startsWith('You are a security monitor'), true],
  ['pass2',       'layer-pass2.txt',       d => d.includes('Err on the side of blocking'), true],
];
const needle = DEC + '("';
const hits = new Map();
let idx = 0;
while ((idx = text.indexOf(needle, idx)) >= 0) {
  const s = idx + needle.length, e = text.indexOf('"', s);
  if (e < 0) break;
  const blob = text.slice(s, e);
  if (/^[A-Za-z0-9+/=]+$/.test(blob) && blob.length > 300) {
    let d; try { d = decode(blob); } catch { d = null; }
    if (d !== null) for (const [name, , pred] of specs)
      if (!hits.has(name) && pred(d)) hits.set(name, { s, e, blob, dec: d });
  }
  idx = e;
}
for (const [name, , , opt] of specs) if (!hits.has(name) && !opt) { console.error('target blob not found: ' + name); process.exit(1); }
for (const [name, , , opt] of specs) if (!hits.has(name) && opt) console.log('  [i] 代际层不存在，跳过: ' + name);

const edits = [];
for (const [name, file] of specs) {
  const h = hits.get(name);
  if (!h) continue;
  const newText = fs.readFileSync(fork + '/' + file, 'utf8').trim() + '\n';
  edits.push({ name, s: h.s, e: h.e, old: h.blob, text: newText, enc: encode(newText) });
  console.log('  ' + name.padEnd(11) + ' old=' + h.dec.length + '  new=' + newText.length);
}
for (const ed of edits.slice().sort((a, b) => b.s - a.s))
  text = text.slice(0, ed.s) + ed.enc + text.slice(ed.e);

// ---- write payload ----
fs.writeFileSync(out, text, 'utf8');

// ---- verify ----
const back = fs.readFileSync(out, 'utf8');
let ok = true;
for (const ed of edits) {
  const rt = decode(ed.enc).trim();
  const pass = rt === ed.text.trim() && !back.includes(ed.old);
  console.log('  verify ' + ed.name.padEnd(11) + pass + '  rtLen=' + rt.length + '  tgtLen=' + ed.text.trim().length + '  oldStillPresent=' + back.includes(ed.old));
  if (!pass) ok = false;
}
const hook = back.includes('/.qoder-cn/persona.txt');
const fb1 = back.includes('return "You are a Qoder agent."})()');
const tpl = /return `You are \$\{[A-Za-z_$][\w$]*\}\.`\}\)\(\)/.test(back);
console.log('  persona hook=' + hook + '  identity fallback1=' + fb1 + '  identity fallback2(closed template)=' + tpl);
if (!(ok && hook)) { console.error('verification failed'); process.exit(1); }
console.log('OK bytes=' + Buffer.byteLength(back));
ENGINE_EOF
}

# ---------- status ----------
cmd_status() {
  if W=$(detect_worker); then
    VER=$(qoder_version "$W")
    say "worker 弹体 : $W"
    say "Qoder 版本   : $VER"
    if is_armored "$W"; then state=装甲弹; else state=官方原版; fi
    say "现役状态     : $state  $(wc -c < "$W" | tr -d ' \t') B  sha256=$(sha256_of "$W")"
    for b in "$W".official.bak-*; do
      [ -f "$b" ] && say "官方备份     : $(basename "$b")  $(wc -c < "$b" | tr -d ' \t') B  sha256=$(sha256_of "$b")"
    done
    [ -w "$W" ] || warn "对现役弹体无写权限——deploy 需要 sudo。"
  else
    say "worker 弹体 : 未探测到（既无 /usr/lib/qoder-cn，也无 /opt/* 布局）"
  fi
  for f in $LAYER_FILES; do
    if [ -f "$FORK/$f" ]; then say "弹药层       : $f  $(wc -c < "$FORK/$f" | tr -d ' \t') B"
    else warn "弹药层缺失   : $FORK/$f"; fi
  done
  PP=$(persona_path)
  if [ -f "$PP" ]; then say "人格文件     : $PP  $(wc -c < "$PP" | tr -d ' \t') B"
  else say "人格文件     : 缺失（$PP）——装甲版将回退官方身份"; fi
  PIDS=$(running_qoder_pids)
  [ -n "$PIDS" ] && warn "Qoder 正在运行（pid: $PIDS）——部署前先完全退出，或 deploy --kill"
  return 0
}

# ---------- build（只造弹+自校验，不动系统） ----------
cmd_build() {
  W=$(require_worker)
  require_ammo
  [ -n "$BUILD_OUT" ] || BUILD_OUT="/tmp/qoder_armor_$(qoder_version "$W").mjs"
  TMPJS=$(mktemp /tmp/qoder_engine.XXXXXX.cjs); trap 'rm -f "$TMPJS"' EXIT
  write_engine "$TMPJS"
  "$NODE_BIN" "$TMPJS" "$W" "$BUILD_OUT" "$FORK" || die "造弹失败（见上方引擎输出）"
  "$NODE_BIN" --check "$BUILD_OUT" >/dev/null 2>&1 || die "弹体语法自检失败（node --check）——拒绝出弹。"
  say "[+] 弹体已造出并自校验通过（含语法闸）→ $BUILD_OUT  $(wc -c < "$BUILD_OUT" | tr -d ' \t') B  sha256=$(sha256_of "$BUILD_OUT")"
}

# ---------- deploy ----------
cmd_deploy() {
  W=$(require_worker)
  VER=$(qoder_version "$W")
  require_ammo
  [ -w "$W" ] || die "无写权限: $W —— 用 sudo 重跑本命令。"

  PIDS=$(running_qoder_pids)
  if [ -n "$PIDS" ]; then
    [ "$KILL_FLAG" = 1 ] || die "Qoder 正在运行（pid: $PIDS）。先完全退出目标应用，或加 --kill。"
    kill_qoder
    say "[i] 已结束运行中的 Qoder（pid: $PIDS）"
  fi

  BAK="$W.official.bak-$VER"
  if is_armored "$W"; then
    [ -f "$BAK" ] || die "现役已是装甲但无官方备份（$BAK 缺失）。先 restore 或重装官方包，再部署。"
    BASE="$BAK"
    say "[i] 现役为装甲 → 从官方备份洗弹重建（官方备份保持不动）"
  else
    cp -f "$W" "$BAK"
    cmp -s "$W" "$BAK" || die "备份自校验失败（cmp 不一致），中止。"
    say "[+] 官方原版已备份 → $(basename "$BAK")  sha256=$(sha256_of "$BAK")"
    BASE="$W"
  fi

  TMPJS=$(mktemp /tmp/qoder_engine.XXXXXX.cjs); OUT=$(mktemp /tmp/qoder_armor.XXXXXX.mjs)
  trap 'rm -f "$TMPJS" "$OUT"' EXIT
  write_engine "$TMPJS"
  "$NODE_BIN" "$TMPJS" "$BASE" "$OUT" "$FORK" || die "造弹失败（见上方引擎输出）"
  "$NODE_BIN" --check "$OUT" >/dev/null 2>&1 || die "弹体语法自检失败（node --check）——中止，现役弹体未动。"

  cp -f "$OUT" "$W"
  cmp -s "$OUT" "$W" || die "部署自校验失败（弹体与现役不一致），中止——官方备份仍在 $BAK。"
  say "[+] 装甲已上膛 → $W  sha256=$(sha256_of "$W")"

  PP=$(persona_path)
  if [ ! -f "$PP" ] && [ -f "$DEFAULT_PERSONA" ]; then
    mkdir -p "$(dirname "$PP")"
    cp -f "$DEFAULT_PERSONA" "$PP"
    say "[+] 人格已播种 → $PP"
  else
    say "[i] 人格保持现状（$PP）"
  fi
  say ""
  say "完成。启动 Qoder → 新对话生效。"
  say "回滚: sh qoder_pojia.sh restore"
}

# ---------- restore ----------
cmd_restore() {
  W=$(require_worker)
  BAK=$(ls "$W".official.bak-* 2>/dev/null | sort -V | tail -1) || true
  [ -n "$BAK" ] && [ -f "$BAK" ] || die "未找到官方备份（$W.official.bak-*）——无备份不回滚，重装官方安装包兜底。"
  [ -w "$W" ] || die "无写权限: $W —— 用 sudo 重跑本命令。"
  PIDS=$(running_qoder_pids)
  if [ -n "$PIDS" ]; then
    [ "$KILL_FLAG" = 1 ] || die "Qoder 正在运行（pid: $PIDS）。先完全退出，或加 --kill。"
    kill_qoder
  fi
  cp -f "$BAK" "$W"
  cmp -s "$BAK" "$W" || die "恢复自校验失败。"
  say "[+] 官方原版已恢复 ← $(basename "$BAK")  sha256=$(sha256_of "$W")"
}

# ---------- persona ----------
cmd_persona() {
  SRC="${PERSONA_ARG:-$DEFAULT_PERSONA}"
  [ -f "$SRC" ] || die "人格源不存在: $SRC"
  PP=$(persona_path)
  if [ -f "$PP" ] && [ "$PERSONA_FORCE" != 1 ]; then
    say "[i] 人格已存在，不覆盖（-f 强制）: $PP"
  else
    mkdir -p "$(dirname "$PP")"
    cp -f "$SRC" "$PP"
    say "[+] 人格已安装 → $PP  $(wc -c < "$PP" | tr -d ' \t') B  sha256=$(sha256_of "$PP")"
  fi
}

# ---------- hashes ----------
cmd_hashes() {
  W=$(require_worker)
  say "现役   $(sha256_of "$W")  $W"
  for b in "$W".official.bak-*; do [ -f "$b" ] && say "备份   $(sha256_of "$b")  $(basename "$b")"; done
}

case "$CMD" in
  status)  cmd_status ;;
  build)   cmd_build ;;
  deploy)  cmd_deploy ;;
  restore) cmd_restore ;;
  persona) cmd_persona ;;
  hashes)  cmd_hashes ;;
  ""|-h|--help) usage ;;
  *) die "未知子命令: $CMD（--help 看用法）" ;;
esac
