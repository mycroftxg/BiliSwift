# HarborBili 接力任务书（0.3.0 → 0.4.0）

> 依据：Codex 会话 `~/.codex/sessions/2026/11/08/rollout-2026-11-08T17-57-01-….jsonl` 中 32 条用户消息、`work/ACTIVE-TASK.md`、`HANDOFF.md`、`Docs/STATUS.md`，以及本任务书作者在 2026-11-08 20:05 对现有代码、构建、测试和运行进程的实测。
> 读者：接手的 AI 或工程师。先读 `HANDOFF.md` 了解工程约定，再按本文执行。

> **2026-11-08 20:25 更新（0.3.1 build 5 已交付并运行）**：本轮已修复 ① 侧栏按钮重复、并在沉浸播放时隐藏窗口工具栏（保留红绿灯）② UP 主视频误入剧集页导致 -404 ③ 高级格式切换失败会中断播放（改为保留原片源并提示）④ UP 视频时长/播放量显示。剩余重点：T1 真实高级输出验证（需大会员片源）、T3 直播聊天弹幕、T0 git 初始化、T2 Hi-Res 决策。

---

## 0. 交接状态核对（已实测，不是转述）

| 项 | 结论 | 证据 |
|---|---|---|
| 源码 | 3,611 行，Swift 6 / 最低 macOS 26，零第三方依赖 | `wc -l Sources Tests` |
| 构建 | `swift build` 通过（0.84s，增量） | 本次实测 |
| 确定性测试 | 16 项全部通过；2 项 live 测试默认跳过 | `swift test` 本次实测 |
| 联网测试 | 24 项通过（8 播放 + 16 核心），含真实 VOD/PGC/直播 | `work/final-verification.log` |
| 磁盘版本 | 0.3.0 build 4，二进制 mtime 20:00 | `Info.plist` / `ls` |
| **运行进程** | **是 0.3.0**（PID 4774，20:01:18 启动，晚于构建；可执行文件与磁盘同尺寸同路径） | `ps -p 4774 -o lstart`、`lsof -p 4774` |
| 代码签名 | **当前 `codesign --verify --strict` 失败**：`com.apple.FinderInfo` 等 detritus。原因是应用放在 Documents（文件提供器目录），Finder/预览会重新打标 | 本次实测 |
| 版本控制 | **没有 git 仓库**（只有 `.gitignore`） | 本次实测 |
| 直播聊天弹幕 | 未接入，`LiveDetailView` 明确写着"实时聊天弹幕仍待接入" | 源码 |
| 封面 | 搜索页首帧有大量占位灰块，约 1 分钟后首页封面全部正常；同一批 URL 用 curl 均 200 | 20:06 / 20:07 两张截图 + URL 抽检 |

**结论：0.3.0 已在运行，源码可构建可测；但签名被 Finder 破坏、无版本控制、高级格式尚未真正可用（见 §2）。**

---

## 1. 用户已确认的产品要求（不要再自行改方向）

1. 自有 UI 全部 SwiftUI；仅视频渲染表面允许 `AVPlayerLayer` 的 NSView 封装；系统红黄绿窗口控件必须保留。
2. 视觉对齐 Apple TV（贴边大图、自动轮播、分页圆点、横向货架）；侧栏与横向栏目的融合参考 Apple Music。
3. 播放页为本窗口内沉浸式液态玻璃：中央播放/前后跳、底部进度条、右下最右全屏、右上点赞（长按三连）、全部悬浮控件一起自动隐藏、Esc 退出全屏。
4. 会员能力（高码率、HDR、杜比视界、Hi-Res、杜比全景声）**在范围内**，但必须如实区分"片源格式 / 解码就绪 / 真实输出"；不支持要准确提示并回退，**不得伪称已验证**。
5. 写操作（点赞、投币、三连、收藏、关注、发评论/弹幕）**不允许自动化测试**，由用户手动触发验收。
6. 推广类页面（会员购、续费）用系统浏览器打开；消息、完整网页版等非核心页面保留官方网页。
7. 用户要求"汇总需求后统一构建"，不要每改一点就打包重启。

---

## 2. 关键差距（按代码事实，不是猜测）

### 2.1 高级音视频格式：菜单可见，链路未打通

| 事实 | 位置 | 影响 |
|---|---|---|
| `compatibleVideo` 用 `!$0.advanced` 过滤，自动选轨**永远不会选 HDR(125)/杜比视界(126)** | `Sources/HarborBili/Playback.swift:98` | 会员片源自动播放永远走兼容画质 |
| `compatibleAudio` 只接受 `!advanced && mp4a`，**杜比(30250)/Hi-Res(30251) 永不被自动选中**；打开视频时若只有高级音轨会直接报"无兼容音轨" | `Playback.swift:102` | Atmos/Hi-Res 实际不可用 |
| 格式判定只看 quality id，没有解析 init 段的 `stsd / dvcC / dvvC / colr / dec3 / dfLa` | `Models.swift:147`、`MediaGateway.swift:181-211` | 无法区分 HDR10 / HLG / DV P5 / DV P8，也无法识别 Atmos(JOC) 与 FLAC 参数 |
| HLS 只在 125 时写 `VIDEO-RANGE=PQ`，且**写死 PQ** | `MediaGateway.swift:206` | B 站 HDR 若为 HLG，声明错误；杜比视界没有任何 CODECS/SUPPLEMENTAL-CODECS 声明 |
| `outputStatus` 只区分"兼容播放 / 高级输出待设备验证" | `Playback.swift:142` | 没有"真实输出"结论；用户无法判断到底 HDR 了没有 |
| `AVPlayer.eligibleForHDRPlayback` 被当作 HDR 门槛 | `Playback.swift:39,118` | 这只是解码/系统链路，**不等于显示端支持 EDR**；内建非 XDR 屏应判为 SDR |

### 2.2 其它待办
- 直播实时聊天弹幕：未接入（`LiveDetailView.swift`）。
- 搜索页封面灰屏：待排查（疑似 `AsyncImage` 生命周期/取消/缓存，而非 URL 无效）。
- 签名 detritus：`com.apple.FinderInfo` 会被 Finder 反复写回。
- 无 git：任何一次失误都无法回滚。

---

## 3. 任务清单

### T0 交接卫生（0.5 小时，先做）
1. `git init` + 首次提交（`.gitignore` 已存在，确认忽略 `.build/`、`*.app`、`work/` 中产物）。
2. 清理签名干扰并复核：
   ```bash
   xattr -cr HarborBili.app
   codesign --verify --strict --deep HarborBili.app
   ```
   若仍失败，用 `./Scripts/build-app.sh release` 重新打包（脚本内部会重签并自校验）。
3. 打开应用 → 设置 → 关于，确认显示 **0.3.0 (4)**，与本文 §0 的进程判断一致。
4. 记录基线：`swift test`、`HARBOR_LIVE_TESTS=1 swift test --no-parallel` 各跑一次，结果写入 `work/relay-baseline.log`。

**验收**：`codesign --verify --strict` 返回 0；about 页面版本 0.3.0 (4)；两项测试与 §0 一致。

---

### T1 高级格式真实链路（P0，核心，1.5–2 天）

> 目标：把"HDR / 杜比视界 / 杜比全景声 / Hi-Res"从"菜单里能点"变成"能取流、能解码、能正确声明、能如实报告输出状态、失败能回退"。

**T1.1 新增格式探测（`HarborCore/FormatInspector.swift`）**
- 解析 init 段（`MediaTrack.initialization` 的字节，网关已能取到）：
  - `stsd` 的 sample entry：`avc1 / hvc1 / hev1 / dvh1 / dvhe / av01 / ec-3 / fLaC`
  - `dvcC` / `dvvC`：DV profile / level / `bl_signal_compatibility_id` → 判 DV P5 / P8
  - `hvcC` + `colr`：`colour_primaries` / `transfer_characteristics` → HDR10(PQ) vs HLG
  - `dec3`：是否 JOC（Atmos）
  - `dfLa`：FLAC 采样率 / 位深 / 声道
- 输出 `SourceFormat { sdr, hdr10, hlg, dolbyVision(profile), atmos, hiRes(sampleRate,bitDepth) }`。

**T1.2 修正 HLS 声明（`MediaGateway.prepare`）**
- HDR：按 `colr` 实际值写 `VIDEO-RANGE=PQ` 或 `HLG`，不要写死。
- 杜比视界：`CODECS="hvc1…"` + `SUPPLEMENTAL-CODECS="dvh1.05.06/db4h"`（按实测 profile 生成）。
- Atmos：`#EXT-X-MEDIA:TYPE=AUDIO,…,CHANNELS="16/JOC"`，`CODECS` 保留 `ec-3`。
- 音频 rendition 单独成 m3u8（现有实现已如此），切换音轨时只换 rendition。

**T1.3 音频轨选择与回退**
- 打开视频时，`compatibleAudio` 改为：优先 `mp4a` 兼容轨 → 用户偏好（Atmos > Hi-Res > AAC）→ 失败回退 AAC，并把回退原因写进 `notice`。
- 允许菜单里选杜比 / Hi-Res 音轨（`audioChoices` 已包含），`choose(audio:)` 要处理"高级音轨不可解码"的失败路径，不能卡在 loading。

**T1.4 输出状态与诊断**
- `outputStatus` 拆成三段显示：`片源格式` / `解码状态` / `实际输出`。
- 新增显示能力判断：`NSScreen.maximumExtendedDynamicRangeColorComponentValue > 1` 才有 EDR；`AVPlayer.eligibleForHDRPlayback` 只用于解码侧。
- 播放页"格式诊断"面板：屏幕 EDR 值、音频输出设备名与采样率、codec、分辨率、帧率、码率、音轨 id。
- **内建屏（本机 Liquid Retina，非 XDR）必须显示 `输出：SDR（屏幕不支持 HDR）`**，而不是"已就绪"。

**T1.5 自动策略**
- 设置→播放增加"优先格式"：`兼容优先（默认）/ 画质优先 / HDR 优先 / 杜比视界优先`。
- 自动选轨时按策略 + 设备能力决定；不满足时回退并在 UI 说明原因。

**验收（需用户配合，见 §5）**
- 大会员账号打开 HDR 片源：菜单可选、能播、诊断面板显示真实片源格式与真实输出结论。
- 杜比视界片源：支持端不绿屏/黑屏，不支持端自动回退并提示。
- 杜比全景声片源：音轨可切换；无 Atmos 通路时下混且标注。
- 以上任一失败：不崩溃、有明确错误文案、可回退到兼容画质/音轨。
- 新增单测：FormatInspector 用真实 init 样本（可用 `work/` 下的抓包）覆盖 DV/HDR/ATMOS/FLAC 四种；HLS 声明快照测试。

---

### T2 Hi-Res 决策点（先验证，再决定）
- 先做一次最小验证：把 `dash.flac.audio` 作为 HLS audio rendition 交给 AVPlayer，看 `AVPlayerItem` 是否能 readyToPlay 且 `AVAssetTrack` 有音频格式。
- 支持 → 并入 T1；不支持 → 单独评估"双流同步（AVAudioEngine + 视频时钟漂移校正）"，**需用户明确同意再投入**，默认回退 AAC 并标注。

---

### T3 直播实时聊天（0.5–1 天）
- 新增 `LiveChat` actor：`URLSessionWebSocketTask` 连接 `wss://broadcastlv.chat.bilibili.com/sub`，token 来自 `/xlive/web-interface/v1/second/getDanmuInfo?id=<room_id>`。
- 协议：auth 包（protover 3）+ 30s 心跳 + 解包（zlib / brotli 需用系统 Compression 或自写解压，B 站现在多为 protover 3）。
- UI：`LiveDetailView` 右侧或下方聊天面板，限流滚动、只读展示；发送弹幕作为可选后续。
- 验收：进入直播间 5s 内出现消息、断线重连、切房释放连接、无内存增长。

---

### T4 视觉验收与已知问题修复（与 T1 并行）
用用户截图逐项过：
1. 宽/窄窗口自适应、轮播圆点、背景延伸到侧栏后方。
2. 详情页固定返回/分享、封面可见时工具栏透明、滚出后模糊。
3. 播放器：HUD 全部自动隐藏、红绿灯可见、Esc 行为、全屏按钮最右。
4. 选集弹层首次点击尺寸正确。
5. **搜索页封面占位排查**：首帧抓取时多张封面是灰块，1 分钟后首页全部正常，同一 URL curl 200 → 更像加载延迟/被取消，而不是 URL 失效。检查 `Thumbnail`/`AsyncImage` 在 `LazyVGrid` 复用中是否被取消、是否缺失败重试与淡入，避免"看起来像坏图"。

**验收**：用户逐项确认；封面首屏占位时间明显缩短，失败可重试并显示占位图。

---

### T5 写操作验收（只能用户手动）
- 点赞、长按三连、投币、收藏、关注、发评论、发弹幕。
- 每个操作：UI 反馈 + 服务端结果回读（刷新页面/重新进入确认状态持久）。
- **禁止** AI 自动执行（三连有真实投币/收藏副作用）。

---

### T6 全量 QA（1 天）
- 36 分区逐一进入、翻页到底、空态/错误态。
- UP 空间：资料、代表作、动态、合集、收藏、追番、专栏、音频各栏目，含未登录/风控分支。
- 网络异常：断网、超时、播放地址过期（120 分钟）、412/-352。
- 长时播放 1 小时：内存、CPU、弹幕帧率、发热。
- VoiceOver 基本可用性；键盘快捷键。

---

### T7 发布 0.4.0
- 版本：`Scripts/Info.plist` 改 `0.4.0` / build `5`；同步 `CHANGELOG.md`、`Docs/STATUS.md`、`README.md`。
- 构建：`./Scripts/build-app.sh release`；打包后**必须退出旧进程再打开**，在"关于"确认版本。
- 可选：Developer ID 签名 + 公证（需要用户提供开发者账号）。

---

## 4. 建议批次（避免每改一点就打包）

| 批次 | 内容 | 产出 |
|---|---|---|
| A | T0 + T1.1/T1.2 + 诊断面板 | 能如实显示片源格式与输出状态 |
| B | T1.3/T1.4/T1.5 + T4 封面与视觉修复 | 高级音轨可切换、封面稳定 |
| C | T2 决策 + T3 直播聊天 | Hi-Res 结论 + 直播弹幕 |
| D | T6 QA + T5 用户验收 + T7 发布 | 0.4.0 |

每批结束统一构建一次，构建后按 `HANDOFF.md` 的流程重启验证。

---

## 5. 需要用户配合的事项

1. **大会员账号**：高级格式验证必须登录（游客拿不到 125/126/30250/30251）。
2. **测试片源**：HDR、杜比视界、杜比全景声、Hi-Res 各 1 支链接；没有则由 AI 从番剧/影视区抓候选给用户确认。
3. **外接 HDR 显示器**（可选但建议）：本机内建屏非 XDR，真 HDR/DV 观感无法在本机验证。
4. **Atmos 输出通路**（可选）：HDMI 接功放/回音壁才能验证直通。
5. **写操作验收**：由用户本人执行并确认。

---

## 6. 红线（沿用并强调）

- 更改应用标识或钥匙串服务名会影响已有登录状态。
- 不绕过 DRM、不伪造会员权益、不把"待验证"写成"已支持"。
- 不对用户账号自动执行任何写操作。
- 自有 UI 不引入 AppKit/第三方 UI 框架；WebKit 仅官方页面。
- 构建产物、源码、运行进程三者版本必须分清；验证以运行进程的"关于"页为准。

---

## 7. 给下一个 AI 的接力提示词（可直接粘贴）

```text
接手一个已存在的原生 macOS 哔哩哔哩客户端 HarborBili（Swift 6 / SwiftUI / macOS 26+，AVFoundation 播放，
零第三方依赖）。工作目录：
HarborBili
应用：上一级 HarborBili.app（0.3.0 build 4，已在运行，PID 4774，启动于 20:01）。
先读 Docs/RELAY-TASK.md、HANDOFF.md、Docs/STATUS.md，再动手；不要重建工程。

当前优先级：
1) T0 交接卫生：git init + 首次提交；xattr -cr 清 FinderInfo 后 codesign --verify --strict；
   在应用"设置→关于"确认 0.3.0(4)。
2) T1 高级格式真实链路：新增 FormatInspector 解析 init 的 stsd/dvcC/dvvC/colr/dec3/dfLa；
   修正 HLS 的 VIDEO-RANGE / SUPPLEMENTAL-CODECS / CHANNELS(JOC) 声明；
   放开杜比与 Hi-Res 音轨选择并做失败回退；outputStatus 拆成"片源格式/解码状态/实际输出"，
   内建非 XDR 屏必须显示 SDR 而不是"已就绪"。
   现状证据：Playback.swift:98 过滤 !advanced、:102 只收 mp4a、MediaGateway.swift:206 写死 VIDEO-RANGE=PQ。
3) T4 修搜索页封面灰屏（URL 可访问，疑 AsyncImage 生命周期/取消）。
4) T3 接直播聊天弹幕（WebSocket broadcastlv + getDanmuInfo token）。
5) 写操作只让用户手动验收，不要自动化；不绕过 DRM；不宣称未验证能力。

构建与验收：
  swift build
  swift test
  HARBOR_LIVE_TESTS=1 swift test --no-parallel
  ./Scripts/build-app.sh release   # 之后必须退出旧进程再打开，设置→关于确认版本
用户要求汇总改动后统一构建，不要每改一点就打包。
```

---

*本文档由 DSH 会话于 2026-11-08 20:07 生成，事实核对时间 20:05–20:07。*
