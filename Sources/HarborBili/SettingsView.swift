import SwiftUI
import HarborCore

private enum SettingsSection:String,CaseIterable,Identifiable {
    case account="账号",appearance="外观",playback="播放",text="弹幕与字幕",sidebar="侧栏",privacy="隐私",about="关于"
    var id:String { rawValue }
    var symbol:String { switch self { case .account:"person.crop.circle";case .appearance:"paintpalette";case .playback:"play.circle";case .text:"text.bubble";case .sidebar:"sidebar.left";case .privacy:"hand.raised";case .about:"info.circle" } }
}
struct SettingsView:View {
    @Environment(AccountSession.self) private var account
    @Environment(LocalLibrary.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.openURL) private var openURL
    @State private var section:SettingsSection? = .account
    @State private var login=false
    @State private var clearHistory=false
    @State private var reset=false
    @Environment(UpdateController.self) private var updater
    var body:some View {
        NavigationSplitView {
            List(SettingsSection.allCases,selection:$section) { item in Label(item.rawValue,systemImage:item.symbol).tag(item) }
                .navigationSplitViewColumnWidth(160)
        } detail: {
            Group {
                if section == .sidebar { SidebarPreferencesView() }
                else { Form { fields }.formStyle(.grouped) }
            }.navigationTitle(section?.rawValue ?? "设置")
        }.frame(width:800,height:650)
            .sheet(isPresented:$login) { LoginSheet().environment(account) }
            .confirmationDialog("清除本机观看记录？云端历史不会被删除。",isPresented:$clearHistory,titleVisibility:.visible) { Button("清除本机记录",role:.destructive) { library.clear() } }
            .confirmationDialog("恢复所有偏好设置？账号和观看历史会保留。",isPresented:$reset,titleVisibility:.visible) { Button("恢复默认",role:.destructive) { preferences.reset() } }
    }
    @ViewBuilder private var fields:some View {
        @Bindable var prefs=preferences
        switch section ?? .account {
        case .account:
            Section {
                HStack(spacing:14) {
                    AvatarView(source:account.avatar,size:58)
                    VStack(alignment:.leading,spacing:4) { Text(account.name).font(.title2.bold());Text(account.loggedIn ? (account.vip ? "大会员":"普通账号"):"登录后同步你的资料库").foregroundStyle(.secondary) }
                }.padding(.vertical,8)
                if account.loggedIn {
                    LabeledContent("UID",value:String(account.mid))
                    Button("账号管理 ↗") { openURL(URL(string:"https://account.bilibili.com/")!) }
                    Button("退出登录",role:.destructive) { Task { playback.stop();await account.logout() } }.disabled(account.busy)
                } else { Button("登录哔哩哔哩") { login=true }.buttonStyle(.glassProminent) }
            }
            Section("会员") {
                Text("会员画质与音轨以账号权限和片源为准。高级格式的实际输出状态可在播放器信息中查看。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("管理大会员 ↗") { openURL(URL(string:"https://account.bilibili.com/big")!) }
            }
            if let message=account.message { Text(message).foregroundStyle(.red) }
        case .appearance:
            Section("显示") {
                Picker("外观",selection:$prefs.values.appearance) { Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark") }.pickerStyle(.segmented)
                Toggle("低电量模式",isOn:$prefs.values.lowPowerMode)
                Text("暂停轮播自动切换、减少头图预加载，弹幕降到 30fps；适合 MacBook Air 长时间使用。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("采用 macOS 原生材质与液态玻璃。系统的减少透明度、增强对比度设置由系统组件处理。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("界面") { Text("首页与详情页采用贴边大图和横向栏目；播放在当前窗口内展开。侧栏栏目可在“侧栏”中自定义。") }
            Section("内容海报") {
                TextField("TMDB API Token（可选）",text:$prefs.values.tmdbToken).textFieldStyle(.roundedBorder)
                Text("填入 TMDB v4 Read Access Token 后，番剧/国创/电影/电视剧/纪录片会优先使用 TMDB 竖版海报；留空则显示哔哩哔哩官方封面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .playback:
            Section("默认播放") {
                Picker("默认画质",selection:$prefs.values.quality) { Text("均衡 · 最高 1080P").tag("balanced");Text("节省流量 · 最高 480P").tag("data");Text("优先清晰 · 最高可用 SDR").tag("highest") }
                Picker("视频编码偏好",selection:$prefs.values.codec) { Text("自动 · 优先兼容").tag("auto");Text("H.264").tag("avc1");Text("HEVC").tag("hevc");Text("AV1").tag("av01") }
                Picker("默认播放高级格式",selection:$prefs.values.preferredFormat) {
                    Text("自动 · 优先兼容").tag("auto")
                    Text("优先 HDR").tag("hdr")
                    Text("优先杜比视界").tag("dolbyVision")
                    Text("优先 4K").tag("uhd")
                }
                Picker("默认倍速",selection:$prefs.values.rate) { ForEach([0.5,0.75,1,1.25,1.5,2],id:\.self) { Text("\($0.formatted())×").tag($0) } }
                LabeledContent("默认音量") { Slider(value:$prefs.values.volume,in:0...1).frame(width:180);Text(prefs.values.volume,format:.percent.precision(.fractionLength(0))).monospacedDigit().frame(width:42) }
                Toggle("打开详情时自动播放",isOn:$prefs.values.autoPlay)
                Toggle("从上次进度继续播放",isOn:$prefs.values.resume)
            }
            Section("控制栏") {
                Toggle("播放时自动隐藏悬浮控制栏",isOn:$prefs.values.autoHide)
                Text("停止移动 1 秒后自动隐藏；移出窗口或全屏时指针会一起隐藏，移动指针即可恢复。暂停时保持显示。Esc 退出全屏，再按 Esc 返回详情。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("高级播放") { Text("「默认播放高级格式」会在片源提供时自动选择 HDR / 杜比视界 / 4K；显示设备不支持时会如实提示并按 SDR 呈现。音频仍默认兼容音轨，可在播放器中切换杜比 / Hi-Res，不能把系统就绪当作已验证高级输出。")
                .font(.callout).foregroundStyle(.secondary) }
        case .text:
            Section("弹幕") {
                Toggle("默认显示弹幕",isOn:$prefs.values.danmaku)
                LabeledContent("不透明度") { Slider(value:$prefs.values.danmakuOpacity,in:0.2...1).frame(width:180) }
                Picker("字号",selection:$prefs.values.danmakuSize) { Text("小").tag(15.0);Text("标准").tag(17.0);Text("大").tag(21.0);Text("特大").tag(25.0) }
                Picker("滚动速度",selection:$prefs.values.danmakuSpeed) {Text("舒缓").tag(0.75);Text("标准").tag(1.0);Text("较快").tag(1.25)}
                Picker("同屏密度",selection:$prefs.values.danmakuDensity) { Text("精简").tag(12);Text("标准").tag(24);Text("丰富").tag(40) }
                Text("开启系统减少动态效果时，弹幕将采用静态显示。复杂高级弹幕暂不呈现。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("字幕") { Picker("字幕字号",selection:$prefs.values.subtitleSize) { Text("小").tag(17.0);Text("标准").tag(20.0);Text("大").tag(25.0);Text("特大").tag(30.0) };Text("字幕语言在播放器中选择，取决于片源提供的字幕。 ").font(.caption).foregroundStyle(.secondary) }
        case .privacy:
            Section("观看记录") {
                Toggle("保存本机观看进度",isOn:$prefs.values.saveHistory)
                Toggle("登录后同步观看进度到哔哩哔哩",isOn:$prefs.values.syncHistory)
                LabeledContent("本机记录",value:"\(library.records.count) 条")
                Button("清除本机观看记录…",role:.destructive) { clearHistory=true }
            }
            Section("登录与数据") {
                Text("登录凭据保存在本机钥匙串。退出登录将清除本应用的登录凭据及官方网页数据。本机观看记录独立管理。应用没有自建服务或统计上传。")
                    .font(.callout).foregroundStyle(.secondary)
                if let notice=library.notice { Text(notice).foregroundStyle(.red) }
            }
            Section { Button("恢复所有偏好设置…") { reset=true } }
        case .about:
            Section {
                Label("BiliSwift",systemImage:"play.rectangle.fill").font(.largeTitle.bold())
                Text("原生 macOS 哔哩哔哩客户端").foregroundStyle(.secondary)
                LabeledContent("版本",value:"\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "源码预览") · 开发预览")
                LabeledContent("界面",value:"SwiftUI · Liquid Glass")
                LabeledContent("播放",value:"AVFoundation · 本机 HLS 适配")
                Text("非哔哩哔哩官方应用。网页版接口与会员高级输出仍在验证中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("软件更新") {
                LabeledContent("当前版本",value:updater.currentVersion)
                UpdateSourcePicker(preferences: prefs)
                Button(updater.checking ? "检查中…":"检查更新") {
                    Task { await updater.check() }
                }.disabled(updater.checking || updater.downloading)
                if !updater.status.isEmpty { Text(updater.status).font(.caption).foregroundStyle(.secondary) }
                if let release=updater.release {
                    if let notes=release.notes,!notes.isEmpty { Text(notes).font(.callout) }
                    Button(updater.downloading ? "正在下载…":"下载并打开 DMG") { Task { await updater.downloadAndOpen(using:UpdateController.Source(rawValue:prefs.values.updateSource) ?? .auto) } }.disabled(updater.downloading)
                    Link("打开发布页",destination:release.page)
                }
                if let error=updater.error { Text(error).font(.caption).foregroundStyle(.red) }
                Text("从 GitHub 检查版本并获取校验信息。下载较慢时可切换镜像。").font(.caption).foregroundStyle(.secondary)
            }
            Section("官方服务") {
                Link("哔哩哔哩",destination:URL(string:"https://www.bilibili.com/")!)
                Link("会员购",destination:URL(string:"https://show.bilibili.com/")!)
                Link("创作中心",destination:URL(string:"https://member.bilibili.com/")!)
            }
        case .sidebar: SidebarPreferencesView()
        }
    }
}
struct SidebarPreferencesView:View {
    @Environment(AppPreferences.self) private var preferences
    var body:some View {
        List {
            Section {
                Text("选择显示在侧栏中的官方分区，使用箭头调整顺序。更改会立即保存。")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical,6)
                Button("恢复默认分区") { preferences.values.channelIDs=BiliChannel.defaultIDs }
            }
            Section("已显示") {
                ForEach(preferences.channels) { channel in
                    HStack {
                        Label(channel.title,systemImage:channel.symbol)
                        Spacer()
                        Button { preferences.moveChannel(channel.id,by: -1) } label:{ Image(systemName:"chevron.up") }.help("上移").disabled(preferences.values.channelIDs.first==channel.id)
                        Button { preferences.moveChannel(channel.id,by:1) } label:{ Image(systemName:"chevron.down") }.help("下移").disabled(preferences.values.channelIDs.last==channel.id)
                        Button { preferences.toggleChannel(channel.id,false) } label:{ Image(systemName:"minus.circle") }.help("从侧栏隐藏")
                    }.buttonStyle(.borderless).padding(.vertical,3)
                }
            }
            Section("所有分区") {
                ForEach(BiliChannel.all) { channel in
                    Toggle(isOn:Binding(get:{preferences.values.channelIDs.contains(channel.id)},set:{preferences.toggleChannel(channel.id,$0)})) { Label(channel.title,systemImage:channel.symbol) }
                }
            }
        }
    }
}
struct AvatarView:View {
    let source:String
    var size:CGFloat=40
    var body:some View {
        RemoteImage(source:source,width:Int(size*2),square:true)
            .frame(width:size,height:size).clipShape(.circle).accessibilityHidden(true)
    }
}
