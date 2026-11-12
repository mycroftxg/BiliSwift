# 给下一位 AI 的接力提示词

请接手继续改进这个已经存在的原生 macOS 哔哩哔哩客户端，先阅读现有代码和本文，不要重新创建项目。用户要求尽可能使用 Apple 官方框架，所有应用自有 UI 使用 SwiftUI，视觉与布局参考 Apple TV；横向栏目与侧栏的融合参考 Apple Music。

> **先看 [`Docs/RELAY-TASK.md`](Docs/RELAY-TASK.md)**：其中包含 2026-11-08 20:05 的交接状态实测（0.3.0 已在运行、签名被 Finder 破坏、无 git）、按代码事实列出的高级格式差距，以及 T0–T7 任务清单与验收标准。本文保留工程约定与历史背景。


## 工程与当前交付

- 工作目录：`/Users/mycroft/Documents/Codex/2026-11-08/new-chat-3`
- Swift Package 工程：`HarborBili`
- 最新应用：`HarborBili.app`
- 版本 **0.3.4，build 10**，Release 构建已完成（2026-11-08 20:4x，含首页滚动/头图自适应修复）。
- 当前工具链 Xcode 27.2 / Swift 6，Apple Silicon / macOS 27.2；最低部署 macOS 26。
- 最终联网测试 **24 项通过**（HarborPlaybackTests 8 项、HarborCoreTests 16 项）。记录在工作目录的 `work/final-verification.log`。构建记录为 `work/final-package.log`。
- 应用在 `~/Documents`（文件提供器目录）里运行时，`com.apple.FinderInfo` 会被 Finder 立即写回，导致对原地应用执行 `codesign --verify --strict` 报 detritus；把应用复制到 /tmp 或打包成 zip 后校验可通过（已实测）。签名本身有效，构建脚本已在签名前后各清理一次 xattr。
- 运行进程已是 0.3.1（build 5）：重启后 PID 与磁盘二进制一致，侧栏与首页正常。重新签名后首次启动可能弹一次钥匙串授权（`旧版钥匙串服务`），点“始终允许”并输入登录密码即可；每次重新打包签名都会再次出现，属于预期。
- 文档：工程内 `README.md`、`CHANGELOG.md`、`Docs/STATUS.md`。
- 没有第三方依赖，也没有配置远程仓库或提交 PR。

## 用户已经明确的产品要求

1. 自有界面全部 SwiftUI；仅系统视频渲染表面允许 AVPlayerLayer 的 NSView 封装。NSWindow 只做原生窗口操作，系统红黄绿控件应保留；WebKit 仅用于官方验证和允许的非核心网页。
2. 首页和分区：贴边大图、自动轮播、分页圆点、统一 16:9 封面、横向栏目、滑动时内容延伸到玻璃侧栏后方；底部自动加载。双击侧栏首页返回首页顶部。
3. 所有分区视频原生显示，布局与首页相同，不要只嵌网页；番剧影视要有原生剧集详情与选集。
4. 搜索原生分类：综合、视频、番剧、影视、直播、专栏、用户；包含 UP 推荐、近期投稿和排序。搜索框、空状态与结果必须对齐。
5. UP 空间原生统一设计，尽量展示除推广外所有公开元素；资料、头图、统计、公告、代表作、投稿、动态、合集、收藏、追番追剧、专栏、音频、关注与粉丝等分类。
6. 详情页返回/分享固定在工具栏，不随滚动消失；封面可见时顶栏透明，滚出后原生模糊。封面简介悬停展示全文，删除下方重复“简介”折叠项。
7. 同一窗口内沉浸播放，不要再创建独立播放器窗口。中央玻璃播放/前后跳转，顶部音量、返回、点赞；底部玻璃进度条和功能组。全屏位于右下角信息按钮旁的最右侧。所有悬浮播放控件一起自动隐藏，移动指针恢复；Esc 能退出全屏/返回。保留系统窗口控件，去掉蓝色焦点边框。
8. 播放器右上角单击点赞，长按一键三连；避免重复提交，反馈真实服务端结果。
9. 弹幕不能中途消失；按文字宽度、轨道和完整生命周期运行，速度放慢，可调速度，使用 SwiftUI Canvas、目标 60fps。不要再次用“每帧只留最后 N 条”挤掉在场弹幕。
10. 选集弹层首次点击就要完整并正确计算尺寸，不能第二次才正常。
11. 评论头像、字号/字重/行距分层，正文长文折叠，楼中楼预览 3 条并提供展开/更多回复。
12. 完善持久设置页；账号区玻璃融合、不用白色底块、不用三点下拉，只保留设置；退出登录在设置账号页。侧栏分区支持显示/隐藏和排序。
13. 会员高画质、HDR、杜比视界、Hi-Res、杜比全景声都在范围内，但实际账号、片源、设备不支持时要准确提示并回退，不能伪称已验证。会员购、续费等推广页面用系统浏览器。
14. 用户要求汇总需求后统一构建，避免每个小修改都打包重启。未来改动也要把源码、应用包和实际运行进程版本区分清楚。

## 已写入 0.3.0 的实现

- `HarborCore`：JSON/视频/UP/分区模型、WBI、官方网页接口、QR 登录、sidx 解析、HLS 列表和弹幕调度。
- `ContentView.swift`：原生首页、分区、自动分页、双击回顶、滚动工具栏、账号区。`Routes.swift` 用 AppRoute 统一视频、UP 和合集导航。
- `VideoShelf.swift`：HeroCarousel（前 5 项、7 秒自动轮播、可点圆点，减少动态效果时停止自动轮播）、横向背景延伸栏目。
- `Thumbnail` 在 ContentView 内：固定矩形先决定 16:9 尺寸，再叠图裁切，避免图片内在比例改变卡片高度。
- `DetailView.swift`、`SeasonDetailView.swift`：普通视频/剧集原生详情、固定返回分享、简介悬停、选集和评论。
- `SearchView.swift`：原生七类搜索、推荐 UP 与近期稿件、排序。
- `CreatorView.swift`：原生 UP 空间、公开内容各分类、合集导航、验证入口。私有/风控访问失败明确显示，不伪装成空内容。
- `Playback.swift`：AVPlayer、兼容自动选轨、格式切换、失败回退/刷新、字幕、弹幕、本机续播、进度同步。`open(..., episodes:)` 接收完整分集列表；`ensureEpisodes()` 只在缺数据时补拉。
- `PlayerView.swift`：SwiftUI 液态玻璃控件；关闭焦点效果；底部最右全屏；右上点赞/长按三连；选集在准备好数据之后打开弹层，切集保留完整列表。
- `DanmakuTimeline.swift`：CoreText 测量文字宽度、固定速度、轨道准入、密度只影响新弹幕，已入场弹幕不被驱逐。PlayerView 的 Canvas 使用 60fps 目标时间线。
- `MediaGateway.swift`：仅 127.0.0.1 随机端口/随机资源路径。DASH fMP4→HLS 字节范围；直播重写 HLS URI。CDN 不传登录 Cookie，保留 TLS 校验、可信域名、备用镜像。
- 网关退出竞态已修：旧请求不能访问已 invalidated URLSession。跟踪并取消请求和连接，关闭状态阻止新工作，最终在 deinit 失效会话。增加了关闭后拒绝工作的回归测试。
- `LoginView.swift`/Session：原生 QR + 官方网页备选，Keychain 保存。不要更改已有 bundle ID 和钥匙串服务，避免丢登录。
- `Preferences.swift`/`SettingsView.swift`：7 组设置，JSON 向后兼容解码，增加字段不会丢旧偏好。
- `CommentView.swift`：头像、文本层级、预览/展开回复及发布回复界面。

## 已核实的接口细节（不要再猜）

- 当前官方分区 ID 是 1001…1031 等新 ID，已经逐项写入 Channels.swift；不是旧的 1/3/4 那套。
- `/x/web-interface/region/feed/rcmd` 使用 `display_id` 页码、**request_cnt=15**、`from_region`、device=web、plat=30。请求 24 条会返回 62013“没有更多内容”。返回 archives 的 author 是对象，要读 author.name/mid。
- 剧集目录 `/pgc/season/index/result`：season_type 1/2/3/4/5/7 对应番剧/电影/纪录片/国创/电视剧/综艺。
- 剧集详情 `/pgc/view/web/season`；播放 `/pgc/player/web/v2/playurl`，读取 video_info；DRM 明确拒绝，不能绕过。
- 原生搜索 `/x/web-interface/wbi/search/type`，类型 video/bili_user/media_bangumi/media_ft/live/article。用户结果有 res 近期稿件，直播结果的 live_room 是嵌套数组。
- UP 的 `/x/space/wbi/acc/info`、`/x/space/wbi/arc/search` 在当前未登录测试网络触发 -352 或 HTTP 412。资料用 `/x/web-interface/card?mid=...&photo=true` 回退，投稿不能伪造；官方验证后再重试。
- 合集 `/x/polymer/web-space/seasons_series_list`、合集稿件 seasons_archives_list、series/archives。
- 直播推荐 `/room/v1/room/get_user_recommend` 可读；直播流 `/xlive/web-room/v2/index/getRoomPlayInfo` 选 http_hls/avc。旧 second/getList 在测试中被风控。
- 原生扫码返回的 URL 现在可能是 **account.bilibili.com**，不是只允许 passport.bilibili.com。

## 明确未完成/未全面验收

1. **新版实机视觉验收还没完成**：自动化重启超时。优先打开最新包确认版本，检查宽窄窗口、轮播、背景延伸、搜索、固定顶栏、系统窗口控件、HUD 自动隐藏和首次选集。
2. **UP 风控**：测试只区分了读取成功/服务要求验证两条路径，不代表全部 UP 投稿可访问。请保留官方验证入口，不自动解验证码、不反复冲击接口。当前用户已在应用登录，重启应恢复会话，仍需实际检查。
3. **会员高级输出**：源格式识别与试播不等于真实 HDR/Dolby Vision/Hi-Res/Atmos 输出。显示器/音频设备链路、采样参数和元数据尚未全面验证。不要把待验证改成“已支持”。
4. **直播实时聊天弹幕未接入**，原生直播视频链路已测试。
5. 点赞/长按三连/投币/评论/关注等写操作没有自动在用户账号执行。三连有真实投币/收藏副作用，请让用户自行触发验收。
6. 消息/独立关注入口/完整网页版仍为官方网页；UP 专栏/音频目录原生，但正文/音频链接打开官方页面。
7. 所有 UP 页细节、所有权限组合、所有 36 分区逐一 UI、VoiceOver、长时间能耗和各种外接设备尚未全面验收。60fps 是时间线目标，不是已测得持续性能保证。
8. 仅本机临时签名，未做 Developer ID、公证、商店发布和自动更新。

## 构建与验收

在工程目录执行：

```bash
swift build
swift test
HARBOR_LIVE_TESTS=1 swift test --no-parallel
./Scripts/build-app.sh release
```

`swift build` 只更新编译产物，不替换 Finder 应用。打包脚本原子替换同级 HarborBili.app，但不自动退出旧进程。打包后退出旧进程并重新打开，设置→关于确认版本。后续有修改时应同步递增 Info.plist 的版本/build。

联网测试读取真实接口并短时静音播放，禁止为测试自动点赞、投币、三连、评论或关注。旧日志 work/ 内含失败探索记录，不要把旧失败当成最终结果；最终依据 work/final-verification.log 与应用包版本。

请先完成新版本实际 UI 验证，再根据用户新反馈继续改进；不要声称整个 B 站客户端或高级音视频能力已经全部完成。
