# TZCode 破甲工程 · Linux 方式

> 破甲弹项目的 Linux 战线。对位 Windows 侧《TZCode破甲工程-迭代经验归档》§六复现手册，
> 把"官方壳 + 同源破甲弹"的部署/回滚/抓包链完整搬到 Linux。
> 本目录文件同源同步于 `ZhangTanjin/armor-piercer` 与 `ZhangTanjin/-TZCode-pojia`。

## 一、结论先行

- **弹是纯 JS**：`armor_payload.bin` 就是 `zcode.cjs`（15,250,383 B，
  sha256 `840FE6D2DAED8C9D7E5B6BF76DB719B52DDB951CE1A12FC01B82B65B84D06C4E`），
  三个融合标记（`ATOMIC CONTINUATION DISPATCH` / `ZCODE_PERSONA_FILE` 钩 / persona 路径）在位。
  它由壳自带的 Electron Node runtime 执行（`ELECTRON_RUN_AS_NODE` 跑 `zcode.cjs app-server --stdio`），
  **不含任何 Windows 特有字节，跨平台直接复用**。
- **变的只有两件事**：壳的安装路径（Windows `resources\glm\` → Linux `resources/glm/`），
  部署器形态（Win32 四页签 GUI → POSIX sh 脚本）。
- **铁律不变**：壳永远用官方安装包；壳弹同代同源；部署时目标应用必须退出；官方备份永不覆盖。

## 二、阵地地图（源自 electron-builder.config.js + desktop-product-identity.mjs 逆向）

Linux 官方壳打包目标：**AppImage / deb / rpm / pacman** 四种；生产身份
`productName=ZCode`、`linuxExecutableName=zcode`、`linuxPackageName=zcode`
（Preview 身份为 `ZCode Preview` / `zcode-preview` / `zcode-preview`）。

| 阵地 | 安装根 | 弹体路径 | 部署器支持 |
|---|---|---|---|
| deb / rpm / pacman | `/opt/ZCode` | `/opt/ZCode/resources/glm/zcode.cjs` | ✅ 原生支持（需 sudo） |
| Preview 并装 | `/opt/ZCode Preview` | `.../resources/glm/zcode.cjs` | ✅ 自动探测第二候选 |
| AppImage | 只读 squashfs（`/tmp/.mount_*`） | 同上（不可写） | ⚠ 需先 `--appimage-extract`，见 §四 |
| 独立 CLI（install.sh） | `~/.zcode/runtime/current/` | `bin/zcode.mjs`（另一弹种） | ❌ 暂不覆盖，见 §五 |

弹体旁车资产（`resources/glm/packages/*-plugin`、`packages/bundled-skills`、
`.node-bundle-meta.json`）由官方安装包自带——**只换 `zcode.cjs` 一个文件**，与 Windows 侧一致。

## 三、快速开始（deb/rpm/pacman 阵地）

```sh
# 0. 装官方 Linux 壳（壳永不自编），完全退出 ZCode
# 1. 侦察
sh zcode_pojia.sh status
# 2. 上膛（备份官方 → 换弹 → 播种人格；无写权限时自动提示加 sudo）
sudo sh zcode_pojia.sh deploy
# 3. 启动 ZCode（应用菜单或 /opt/ZCode/zcode）→ 新对话生效
# 回滚
sudo sh zcode_pojia.sh restore
```

探测顺序：`ZCODE_INSTALL_ROOT` / `--root` → 运行中进程 `/proc/*/exe` →
`/opt/ZCode` → `/opt/ZCode Preview` → `/usr/lib/zcode` → `/usr/local/lib/zcode`。
等价于 Windows 侧 GUI 的进程路径 + Program Files 三候选探测。

## 四、AppImage 阵地

AppImage 运行时挂载只读 squashfs，写不进去；持久化破甲两条路：

```sh
# 路 A：解包运行（推荐验证用）
./ZCode-*.AppImage --appimage-extract          # → ./squashfs-root/
sudo sh zcode_pojia.sh deploy --root "$PWD/squashfs-root"
./squashfs-root/AppRun                          # 从解包目录启动
# 路 B：把 deb/rpm 换掉 AppImage（长期阵地推荐，探测与更新都更稳）
```

部署器对 `.mount` / `squashfs-root` 路径有专门护栏：`--root` 明确指定才放行。

## 五、独立 CLI 阵地（暂不覆盖）

开源仓自带 `install.sh`（`scripts/zcode-distribution/installer.mjs`）：装到
`~/.zcode/runtime/releases/<版本>/`，`~/.local/bin/zcode` → `node .../current/bin/zcode.mjs`。
入口是 `bin/zcode.mjs` 而非 `glm/zcode.cjs`，属**另一弹种**，当前弹药库未覆盖。
如需开辟：同一备份/回滚模式（`zcode.mjs.official.bak`），弹体待铸。

## 六、Linux 铸弹链（协议变更 / 壳升级时）

```sh
# 1. 源码主权（fork 的 tzcode-main 分支，基线 4f54fef 同源）
git clone <fork> ZCode-src && cd ZCode-src && git checkout tzcode-main
# 2. 装甲补丁（TZCode-pojia/patches/ 四枚，git 原生格式跨平台）
git am ../patches/0004-*.patch ../patches/0005-*.patch ../patches/0006-*.patch ../patches/0008-*.patch
# 3. 构建（Linux 无 MSVC 依赖；node-pty 等原生件走 prebuilds）
pnpm install && pnpm turbo build
# 4. 裸弹出膛
ls apps/zcode-cli/packages/cli/dist/zcode.cjs
# 5. 融合（apply_fusion.ps1 的 python3 等价实现，已与 Windows 产物逐字节比对）
#    若 dist 出膛即带融合标记（装甲补丁已在源码层完成融合），本步跳过——
#    needle absent 报错即此态，直接把 dist 产物当弹体。
python3 ../linux/fuse_round.py apps/zcode-cli/packages/cli/dist/zcode.cjs armor_payload.bin
# 6. 校验三标记
grep -a -c 'ATOMIC CONTINUATION DISPATCH\|ZCODE_PERSONA_FILE' armor_payload.bin
# 7. 部署
sudo sh zcode_pojia.sh deploy --payload ./armor_payload.bin
```

## 七、抓包（终审法官，Linux 版）

```sh
pip install mitmproxy
mitmdump -w capture-linux.flow          # 终端 A（首次运行生成 ~/.mitmproxy CA）
sh proxied-zcode.sh                     # 终端 B：代理+CA 注入启动官方壳
```

对位 Windows `launch-proxied.bat`：`HTTPS_PROXY/HTTP_PROXY/NODE_EXTRA_CA_CERTS/NO_PROXY`
四环境变量注入。GUI 设置等价键为 `httpProxy` / `httpProxyNoProxy` / `httpProxyCaCertPath`
（`packages/shared/src/validationAppSettings.ts`）。复验三要素：
**目标 URL × 鉴权头形态 × 签名头有无**——签名全对也可能投错门。

## 八、与 Windows 链对照

| 环节 | Windows | Linux |
|---|---|---|
| 官方壳 | `ZCode-3.16.3-win-x64.exe` → `%ProgramFiles%\ZCode` | deb/rpm/pacman → `/opt/ZCode` |
| 弹体落点 | `resources\glm\zcode.cjs` | `resources/glm/zcode.cjs` |
| 备份 | `zcode.cjs.official.bak`（GUI 恢复官方） | 同名同制式（`restore` 子命令） |
| 人格 | `~\.zcode\persona\persona.txt` + `ZCODE_PERSONA_FILE` | `~/.zcode/persona/persona.txt` + 同名环境变量 |
| 部署器 | `TY破甲弹.exe`（Win32 四页签，管理员） | `zcode_pojia.sh`（POSIX sh，sudo） |
| 融合 | `apply_fusion.ps1` | `fuse_round.py` |
| 抓包发射 | `launch-proxied.bat` | `proxied-zcode.sh` |
| 弹药 | `armor_payload.bin`（同一枚，跨平台复用） | 同左 |

## 九、已知风险与护栏

1. **壳弹同代同源**：弹与壳版本错配会触发启动校验拒启（3.14.3→3.15.1 旧案）。
   升级壳后必须重铸同源弹；`status` 会打印包版本与双侧 sha256 供比对。
2. **自动更新覆盖**：壳内更新会还原官方 `zcode.cjs`——表现为"破甲突然失效"。
   官方备份仍有效，重新 `deploy` 即可（洗弹语义，备份不覆盖）。
3. **bytecode**：壳有 desktop-agent bytecode 构建线（`dev:desktop:bytecode`）。
   若未来壳对 `zcode.cjs` 做 bytecode/完整性校验导致拒启：`restore` 回滚，
   现象记入账本，回到 §六从现役产物重新逆向。当前 3.15.1/3.16.3 实测接受纯 JS 弹。
4. **备份护栏**：部署器只在"现役为官方原版"时写备份；现役已是破甲弹时只洗弹不动备份；
   现役为破甲弹但备份缺失 → 拒绝部署（无退路不作战）。
5. **部署铁律**：目标应用必须完全退出（检测到进程时 `deploy` 拒绝，`--kill` 显式放行）。

—— RNA @ TZCode 工作台，2026-10-29 Linux 战线开辟

---

## 七、Qoder CN 车道（qoder_pojia.sh ＋ asar_pojia.sh，2026-10-30）

> 与 ZCode 车道的本质差异：Qoder 弹体是 XOR 混淆的 worker 运行时，且**逐版本更换密钥与标识符**
> （0.4.11 `_$d`/`Rni9LeZSmPXE` → 0.5.1 `_$d1`/`OhgmT9svN6AN`）。故部署器内置**版本自适应手术引擎**：
> 按结构嗅探解码器 → 身份双常量钩注入 → 十层内容匹配换弹 → 回环自校验 ＋ `node --check` 语法闸。

### qoder_pojia.sh —— worker 十层装甲
- 目标：`/usr/lib/qoder-cn/app.asar.unpacked/node_modules/@qoder-ai/qoder-cn-agent-sdk/dist/_worker/qoder-worker-runtime.obf.mjs`（pacman `qoder-cn-bin`）
- 十层 ＝ 8 核心（notice / delivering / classifier / rules / judge2 / rules2 / rules3 / automode）＋ 2 代际
  （0.4.x 命中 classifier2＋prefs；0.5.x 命中 monitor 31KB＋pass2；缺席代际层自动跳过）
- 子命令与 zcode_pojia.sh 同构：`status / build / deploy [--kill] / restore / persona / hashes`
- 人格 `~/.qoder-cn/persona.txt` 运行时读取——改文件即生效，无需重部署
- 洗弹重部署一律从官方备份重建（防叠加手术）；升级后直接 `deploy --kill`（0.4.11→0.5.1 实测直通）

### asar_pojia.sh —— app.asar 附件限额解除
- 结构锚点等长替换：`X=200,Y=10,Z=100*1024*1024` → `999 / 999`（单次 200→999 文件，单文件 100MiB→953MiB）
- 锚点按三元组结构匹配，免疫混淆改名（0.4.11 `M60/Fwx` → 0.5.1 `Wg0/ZHx` 实证）；恰好 6 字节差异自校验
- 校验点在主进程 `if(!isFile()||size>Fwx){rejectedCount++}`，渲染层仅显示结果

### 0.4.11 → 0.5.1 升级实录（2026-10-30）
- AUR 未跟进 → 更新器暂存 rpm（sha512 校验）→ AUR PKGBUILD 本地重打包 → `pacman -U` 保持数据库干净
- worker 装甲 `a5bc1ee7`（弹药修订后 `ae4aa270`）；asar 限额弹 `cbcd0f4d`；双官方备份 `.official.bak-*` 在位
- 事故与修复账本：见 `VERIFICATION-Linux-Qoder.txt`
