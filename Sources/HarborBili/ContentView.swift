import SwiftUI
import AppKit
import HarborCore

struct ContentView:View {
    @Environment(AccountSession.self) private var account
    @Environment(LocalLibrary.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.openURL) private var openURL
    @Environment(AppPreferences.self) private var preferences
    @Environment(WindowPresentation.self) private var presentation
    @State private var columns=NavigationSplitViewVisibility.all
    @State private var catalogOverCover=true
    @State private var selection=Destination.home.rawValue
    @State private var customizing=false
    @State private var path:[AppRoute]=[]
    @State private var catalog=Catalog()
    @State private var query=""
    @State private var submitted=""
    @State private var login=false
    @State private var homeJump=UUID()
    @State private var messageRefreshID = UUID()
    @State private var nearBottom=false
    @State private var viewport=CGSize(width:1000,height:800)
    private var route:Destination { Destination(rawValue:selection) ?? .channels }
    private var channel:BiliChannel? { selection.hasPrefix("channel.") ? BiliChannel.find(String(selection.dropFirst(8))):nil }
    private var nativeCatalog:Bool { route == .home || route == .live || channel != nil }
    private var heroHeight: CGFloat { viewport.width * 9 / 16 }
    private var loadKey:String { "\(selection)|\(submitted)|\(account.mid)|\(catalog.folderID)|\(catalog.localHistory)" }
    var body:some View {
        ZStack {
        NavigationSplitView(columnVisibility:$columns) {
            List(selection:$selection) {
                Section {
                    ForEach([Destination.search,.home,.dynamic]) { row($0) }
                }
                Section("分区") {
                    ForEach(preferences.channels) { channel in
                        Label(channel.title,systemImage:channel.symbol).tag("channel."+channel.id)
                    }
                    row(.live)
                }
                Section("更多") { row(.channels);row(.website) }
                Section("资料库") { ForEach([Destination.history,.later,.favorites,.following,.messages]) { row($0) } }
                Section("官方服务") {
                    Button { openURL(URL(string:"https://show.bilibili.com/")!) } label:{ Label("会员购 ↗",systemImage:"bag") }
                    Button { openURL(URL(string:"https://member.bilibili.com/")!) } label:{ Label("创作中心 ↗",systemImage:"square.and.pencil") }
                    Button { openURL(URL(string:"https://account.bilibili.com/big")!) } label:{ Label("大会员 ↗",systemImage:"crown") }
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min:190,ideal:220,max:280)
                .safeAreaInset(edge:.bottom) {
                    HStack(spacing:10) {
                        Button { if account.loggedIn { selection=Destination.space.rawValue } else { login=true } } label:{
                            HStack(spacing:10) {
                                AvatarView(source:account.avatar,size:34)
                                VStack(alignment:.leading,spacing:1) {
                                    Text(account.loggedIn ? account.name:"未登录").font(.headline).lineLimit(1)
                                    Text(account.loggedIn ? (account.vip ? "大会员":"哔哩哔哩账号"):"登录以同步资料库")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .layoutPriority(1)
                            }
                            .frame(maxWidth:.infinity,alignment:.leading)
                            .contentShape(.rect)
                        }.buttonStyle(.plain).help("个人空间").accessibilityLabel("打开个人空间")
                        if !account.loggedIn {
                            Button("登录") { login=true }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.small)
                        } else {
                            SettingsLink { Image(systemName:"gearshape").frame(width:22,height:22) }
                                .buttonStyle(.glass).buttonBorderShape(.circle).help("设置").accessibilityLabel("设置")
                        }
                    }.padding(.horizontal,14).padding(.vertical,12)
                        .glassEffect(.regular,in:.rect(cornerRadius:18))
                        .padding(.horizontal,10).padding(.bottom,10)
                }
        } detail: {
            NavigationStack(path:$path) {
                catalogContent.onGeometryChange(for:CGSize.self) { $0.size } action:{ viewport=$0 }.navigationTitle(presentation.immersive || presentation.toolbarOverCover ? "":channel?.title ?? route.rawValue)
                    .navigationDestination(for:AppRoute.self) { route in
                        switch route {
                        case .video(let video):
                            if video.roomID != nil { LiveDetailView(video:video) }
                            else if video.bvid.hasPrefix("ss") { SeasonDetailView(video:video) }
                            else { DetailView(video:video) }
                        case .creator(let creator): CreatorHomeView(creator:creator)
                        case .dynamic(let item): DynamicDetailView(item:item)
                        case .collection(let collection): CreatorCollectionView(collection:collection)
                        }
                    }
                    .toolbar {
                        ToolbarItem { if !presentation.immersive { Button {
                            if route == .messages { messageRefreshID = UUID() }
                            else { Task { await reload() } }
                        } label:{ Image(systemName:"arrow.clockwise") }.help("刷新").disabled(catalog.loading) } }
                        ToolbarItem { if !presentation.immersive,playback.video != nil { Button("继续播放",systemImage:"play.rectangle") { presentation.immersive=true;playback.player.playImmediately(atRate:playback.rate) } } }
                        ToolbarItem { if !presentation.immersive,!account.loggedIn { Button("登录") { login=true } } }
                    }
            }
        }.toolbar(removing:.sidebarToggle)
            .onChange(of:presentation.immersive) { _,value in if !value { playback.pause() } }
            .opacity(presentation.immersive ? 0:1)
            .allowsHitTesting(!presentation.immersive).accessibilityHidden(presentation.immersive)
        if presentation.immersive {
            HStack(spacing:0) {
                PlayerPanel(immersive:true,onBack:{
                    presentation.leavePlayback();playback.player.pause()
                    if let video=playback.video,path.last?.videoID != video.bvid { path.append(.video(video)) }
                })
                if playback.commentsOpen,playback.video?.roomID == nil {
                    CommentSidebar(aid:playback.commentsAid,bvid:playback.video?.bvid ?? "",tint:playback.videoTint,comments:playback.videoComments,onClose:{ withAnimation(.snappy(duration:0.3)) { playback.commentsOpen=false } })
                        .frame(width:380)
                        .transition(.move(edge:.trailing))
                }
            }
            .background(.black).ignoresSafeArea()
            .animation(.snappy(duration:0.3),value:playback.commentsOpen)
        }
        }.toolbar(removing:.sidebarToggle)
            .toolbarVisibility(.visible,for:.windowToolbar)
            .windowToolbarFullScreenVisibility(.onHover)
            .toolbarBackground(presentation.immersive || presentation.toolbarOverCover ? .hidden:.visible,for:.windowToolbar)
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didEnterFullScreenNotification)) { _ in presentation.refresh() }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didExitFullScreenNotification)) { _ in presentation.refresh() }
            .sheet(isPresented:$customizing) {
                VStack(spacing:0) {
                    HStack { Text("自定义侧栏").font(.title2.bold());Spacer();Button("完成") { customizing=false }.buttonStyle(.glassProminent) }.padding(20)
                    SidebarPreferencesView().environment(preferences)
                }.frame(width:540,height:650)
            }
            .sheet(isPresented:$login) { LoginSheet().environment(account) }
            .task(id:loadKey) { await reload() }
            .onChange(of:selection) { old,new in
                if let url=externalWebURL(new) { openURL(url);selection=old;return }
                path=[];catalogOverCover=nativeCatalog;presentation.toolbarOverCover=nativeCatalog
            }
            .onChange(of:path) { _,value in if value.isEmpty { presentation.toolbarOverCover=catalogOverCover } }
            .onChange(of:account.mid) { _,_ in
                path=[];presentation.leavePlayback();playback.stop();catalog.resetAccountData()
            }
    }
    /// 只存在于官方网页的入口：直接交给系统默认浏览器，App 内不保留网页窗口。
    private func externalWebURL(_ raw:String)->URL? {
        switch raw {
        case Destination.website.rawValue: return URL(string:"https://www.bilibili.com/")
        case Destination.shows.rawValue: return URL(string:"https://show.bilibili.com/")
        case Destination.space.rawValue where !account.loggedIn: return URL(string:"https://passport.bilibili.com/login")
        default: return nil
        }
    }
    private func row(_ destination:Destination)->some View {
        Label(destination.rawValue,systemImage:destination.symbol).tag(destination.rawValue)
            .simultaneousGesture(TapGesture(count:2).onEnded {
                if destination == .home { presentation.leavePlayback();playback.pause();selection=Destination.home.rawValue;path=[];homeJump=UUID() }
            })
    }
    @ViewBuilder private var catalogContent:some View {
        if route == .search {
            NativeSearchView(onVideo:{path.append(.video($0))},onCreator:{path.append(.creator($0))})
        } else if route == .messages {
            MessagesView(refreshID: messageRefreshID)
        } else if route == .following {
            FollowingView()
        } else if route == .dynamic {
            DynamicFeedView(items:catalog.dynamics,loading:catalog.loading,canLoadMore:catalog.canLoadMore,error:catalog.error) { Task { await reload(more:true) } }
        } else if route == .space,account.loggedIn {
            CreatorHomeView(creator:Creator(mid:account.mid,name:account.name,avatar:account.avatar),isRoot:true)
        } else if route == .channels,channel==nil {
            ChannelDirectory { channel in selection="channel."+channel.id }
        } else if channel==nil,[.website,.shows,.space].contains(route) {
            OfficialModule(destination:route,mid:account.mid,channel:channel)
        } else {
            ScrollView {
                VStack(alignment:.leading,spacing:0) {
                    if nativeCatalog,!catalog.videos.isEmpty {HeroCarousel(videos:catalog.videos,height:heroHeight,active:catalogOverCover && path.isEmpty && !presentation.immersive) {path.append(.video($0))}}
                    VStack(alignment:.leading,spacing:24) {
                    if route == .search {
                        HStack { TextField("搜索视频、UP 主或 BV 号",text:$query).textFieldStyle(.roundedBorder).onSubmit { submitted=query }
                            Button("搜索") { submitted=query }.buttonStyle(.borderedProminent)
                        }
                    }
                    if route == .history,account.loggedIn {
                        Picker("历史来源",selection:Binding(get:{catalog.localHistory},set:{catalog.localHistory=$0})) {
                            Text("云端历史").tag(false);Text("本机续播").tag(true)
                        }.pickerStyle(.segmented).frame(maxWidth:300)
                    }
                    if route == .favorites,!catalog.folders.isEmpty {
                        Picker("收藏夹",selection:$catalog.folderID) { ForEach(catalog.folders.indices,id:\.self) { i in Text(catalog.folders[i]["title"].string).tag(catalog.folders[i]["id"].int) } }.frame(maxWidth:400)
                    }
                    if let error=catalog.error {
                        ContentUnavailableView { Label("加载未完成",systemImage:"wifi.exclamationmark") } description:{ Text(error).textSelection(.enabled) } actions:{
                            if route.requiresLogin && !account.loggedIn { Button("登录") { login=true } }
                            Button("重试") { Task { await reload() } }
                        }
                    }
                    if !catalog.videos.isEmpty {
                        HStack { Text(channel?.title ?? (route == .home ? "热门精选":route.rawValue)).font(.title2.bold());Spacer();if route == .home { Text("来自哔哩哔哩热门榜").font(.caption).foregroundStyle(.secondary) } }
                        if let seasonType = channel?.seasonType {
                            PosterGrid(videos:catalog.videos,
                                       token:preferences.values.tmdbToken,
                                       kind:TMDBPosters.Kind(seasonType: seasonType))
                        } else if nativeCatalog {
                            VideoShelf(videos:Array(catalog.videos.prefix(10)))
                            if catalog.videos.count>10 {
                                Text("继续发现").font(.title2.bold())
                                VideoShelf(videos:Array(catalog.videos.dropFirst(10).prefix(10)))
                            }
                            if catalog.videos.count>20 {
                                Text("为你发现更多").font(.title2.bold())
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:220,maximum:360),spacing:20)],alignment:.leading,spacing:26) {
                                    ForEach(Array(catalog.videos.dropFirst(20))) { video in NavigationLink(value:AppRoute.video(video)) { VideoCard(video:video) }.buttonStyle(.plain) }
                                }
                            }
                        } else {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:230,maximum:400),spacing:20)],alignment:.leading,spacing:24) {
                            ForEach(catalog.videos) { video in NavigationLink(value:AppRoute.video(video)) { VideoCard(video:video) }.buttonStyle(.plain) }
                        }
                        }
                        if catalog.canLoadMore {
                            if nativeCatalog { Text(catalog.loading ? "正在发现更多视频…":"继续向下浏览").font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,12) }
                            else { HStack { Spacer();Button("加载更多") { Task { await reload(more:true) } }.disabled(catalog.loading);Spacer() } }
                        }
                    } else if !catalog.loading,catalog.error==nil {
                        ContentUnavailableView(route == .search ? "搜索你想看的内容":"这里还没有视频",systemImage:route.symbol,description:Text(route == .search ? "输入关键词后按回车搜索。":"登录后可查看在线资料库；观看视频后会保存本地进度。"))
                    }
                    if catalog.loading { ProgressView("正在加载…").frame(maxWidth:.infinity).padding() }
                    }.padding(32)
                }
            }.ignoresSafeArea(edges:nativeCatalog ? .top:[])
                .id(selection+homeJump.uuidString)
                .onScrollGeometryChange(for:Bool.self) { geometry in
                    geometry.contentOffset.y+geometry.containerSize.height>geometry.contentSize.height-420
                } action:{ _,value in if nearBottom != value { nearBottom=value;if value { loadNextHomePage() } } }
                .onScrollGeometryChange(for:Bool.self) { geometry in
                    nativeCatalog && geometry.contentOffset.y<heroHeight-65
                } action:{_,value in
                    guard catalogOverCover != value else { return }
                    catalogOverCover=value
                    if path.isEmpty {presentation.toolbarOverCover=value}
                }
                .onChange(of:catalog.loading) { _,loading in if !loading { loadNextHomePage() } }
        }
    }
    private func loadNextHomePage() {
        guard nativeCatalog,nearBottom,!catalog.loading,catalog.canLoadMore,catalog.error==nil,!catalog.videos.isEmpty else { return }
        Task { await reload(more:true) }
    }
    private func reload(more:Bool=false) async {
        await catalog.load(route,keyword:submitted,account:account,library:library,more:more,channel:channel)
    }
}
struct CoverImage:View {
    let source:String
    var width:Int=720
    var showsPlaceholderIcon:Bool=true
    var fit:Bool=false
    var body:some View { RemoteImage(source:source,width:width,showsPlaceholderIcon:showsPlaceholderIcon,fit:fit) }
}
struct VideoCard:View {
    let video:Video
    var seasonBackdropToken: String?
    @State private var seasonBackdrop: NSImage?
    @State private var hovering=false
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            Thumbnail(source:video.cover)
                .overlay {
                    if let seasonBackdrop { SeasonArtwork(image: seasonBackdrop) }
                }
                .overlay(alignment:.bottomTrailing) {
                    if video.roomID == nil {
                        Text(video.durationLabel).font(.caption.monospacedDigit()).padding(5).background(.black.opacity(0.75),in:.rect(cornerRadius:5)).foregroundStyle(.white).padding(7)
                    }
                }
                .overlay(alignment:.topLeading) {
                    if video.roomID != nil {
                        HStack(spacing:4) {
                            Circle().fill(.white).frame(width:5,height:5)
                            Text("直播").font(.caption2.weight(.bold))
                        }.foregroundStyle(.white).padding(.horizontal,7).padding(.vertical,4)
                            .background(.red.opacity(0.9),in:.capsule).padding(7)
                    }
                }
                .clipShape(.rect(cornerRadius:12))
            Text(video.title).font(.headline).lineLimit(2).frame(height:40,alignment:.topLeading)
            Text(video.author+" · "+video.viewLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(.rect)
        .scaleEffect(hovering ? 1.015:1)
        .shadow(color:.black.opacity(hovering ? 0.22:0),radius:hovering ? 12:0,y:hovering ? 6:0)
        .animation(.smooth(duration:0.18),value:hovering)
        .onHover {hovering=$0}
        .accessibilityElement(children:.combine)
        .task(id: video.id) {
            guard let seasonBackdropToken, let seasonID = video.seasonID, seasonID > 0,
                  let detail = try? await BiliAPI.shared.season(seasonID),
                  !Task.isCancelled else { return }
            let backdrop = await TMDBPosters.shared.backdrop(
                for: video, detail: detail, token: seasonBackdropToken, width: 720
            )
            guard !Task.isCancelled else { return }
            seasonBackdrop = backdrop
        }
    }
}
struct HeroCard:View {
    let video:Video,action:()->Void
    var height:CGFloat=540
    var showsCaption=true
    var contained:Bool=false
    @Environment(AppPreferences.self) private var preferences
    @State private var seasonBackdrop: NSImage?
    var body:some View {
        GeometryReader { geometry in
            let textWidth=max(220,min(600,geometry.size.width-88))
            ZStack(alignment:.bottomLeading) {
                Color.clear
                LinearGradient(stops:[.init(color:.clear,location:0.2),.init(color:.black.opacity(0.18),location:0.4),.init(color:.black.opacity(0.85),location:1)],startPoint:.top,endPoint:.bottom)
                LinearGradient(colors:[.black.opacity(0.45),.clear],startPoint:.leading,endPoint:.trailing)
                if showsCaption {
                    HeroCaption(video:video,width:geometry.size.width,height:height,action:action)
                }
            }.frame(width:geometry.size.width,height:height)
            .background {
                ZStack {
                    if video.isSeason {
                        if let seasonBackdrop {
                            SeasonArtwork(image: seasonBackdrop)
                        } else {
                            Color.black
                        }
                    } else {
                        if contained { CoverImage(source:video.cover,width:800).blur(radius:36).opacity(0.7) }
                        CoverImage(source:video.cover,width:1920,showsPlaceholderIcon:false,fit:contained)
                    }
                }
                .frame(width:geometry.size.width,height:height).clipped().backgroundExtensionEffect()
            }
        }.frame(height:height)
            .task(id: video.id) {
                guard video.isSeason, let seasonID = video.seasonID,
                      let detail = try? await BiliAPI.shared.season(seasonID),
                      !Task.isCancelled else { return }
                let backdrop = await TMDBPosters.shared.backdrop(for: video, detail: detail, token: preferences.values.tmdbToken)
                guard !Task.isCancelled else { return }
                seasonBackdrop = backdrop
            }
    }
}

struct HeroCaption:View {
    let video:Video
    let width:CGFloat
    let height:CGFloat
    let action:()->Void
    var body:some View {
        let textWidth=max(220,min(600,width-88))
        VStack(alignment:.leading,spacing:14) {
            HStack(spacing:5) {
                if video.roomID != nil { Circle().fill(.white).frame(width:5,height:5) }
                Text(video.roomID == nil ? "热门精选":"直播中").font(.caption.weight(.semibold))
            }.padding(.horizontal,10).padding(.vertical,5)
                .background(video.roomID == nil ? AnyShapeStyle(.clear):AnyShapeStyle(.red.opacity(0.9)),in:.capsule)
                .glassEffect(video.roomID == nil ? .regular:.identity,in:.capsule)
            Text(video.title).font(.system(size:max(24,min(36,width*0.036)),weight:.bold)).lineLimit(height<420 ? 2:3).frame(maxWidth:textWidth,alignment:.leading)
            Text(video.author+" · "+video.viewLabel).font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Button(action:action) { Label(video.roomID == nil ? "观看视频":"观看直播",systemImage:"play.fill").font(.headline).padding(.horizontal,28).padding(.vertical,10) }
                .buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.white).foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(.horizontal,40).padding(.bottom,44).padding(.top,80)
    }
}

struct Thumbnail:View {
    let source:String
    var body:some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(16/9,contentMode:.fit)
            .overlay { CoverImage(source:source) }
            .clipped()
    }
}
struct ChannelDirectory:View {
    let select:(BiliChannel)->Void
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:26) {
                Text("探索分区").font(.largeTitle.bold())
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:16),count:4),spacing:16) {
                    ForEach(BiliChannel.all) { channel in
                        Button { select(channel) } label:{
                            VStack(spacing:14) {
                                Image(systemName:channel.symbol).font(.system(size:30,weight:.regular)).frame(height:34)
                                Text(channel.title).font(.headline)
                            }
                            .frame(maxWidth:.infinity,minHeight:116)
                            .contentShape(.rect)
                        }.buttonStyle(.glass)
                    }
                }
            }
            .frame(maxWidth:1120,alignment:.leading)
            .frame(maxWidth:.infinity)
            .padding(32)
        }
    }
}
