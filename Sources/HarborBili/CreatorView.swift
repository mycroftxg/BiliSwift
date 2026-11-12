import SwiftUI
import HarborCore

func dumpSpaceDebug(_ object:[String:JSON]) {
    guard let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first,
          let data=try? JSONEncoder().encode(JSON.object(object)) else { return }
    try? data.write(to:directory.appendingPathComponent("harbor-space-debug.json"))
}

private enum CreatorTab:String,CaseIterable,Identifiable {
    case home="主页",videos="投稿",dynamic="动态",collections="合集和列表",favorites="收藏",bangumi="追番",cinema="追剧",articles="专栏",audio="音频",following="关注",fans="粉丝",about="关于"
    var id:String {rawValue}
}
@MainActor @Observable private final class CreatorModel {
    var profile:JSON = .null
    var stats:JSON = .null
    var upstat:JSON = .null
    var notice=""
    var featured:[Video]=[]
    var videos:[Video]=[]
    var posts:[JSON]=[]
    var collections:[CreatorCollection]=[]
    var folders:[JSON]=[]
    var people:[Creator]=[]
    var articles:[JSON]=[]
    var audio:[JSON]=[]
    var categories:[JSON]=[]
    var folder=0
    var category=0
    var page=1
    var offset=""
    var loading=false
    var failure:String?
    var headerFailure:String?
    var more=true
    private var generation=UUID()
    func header(_ mid:Int,selfMid:Int=0) async {
        async let profileRequest=BiliAPI.shared.creator(mid)
        async let statsRequest=BiliAPI.shared.request("/x/relation/stat",["vmid":"\(mid)"])
        async let upstatRequest=BiliAPI.shared.request("/x/space/upstat",["mid":"\(mid)"])
        async let noticeRequest=BiliAPI.shared.request("/x/space/notice",["mid":"\(mid)"])
        async let masterpieceRequest=BiliAPI.shared.request("/x/space/masterpiece",["vmid":"\(mid)"])
        do {profile=try await profileRequest}catch{headerFailure=error.localizedDescription}
        stats=(try? await statsRequest) ?? .null
        upstat=(try? await upstatRequest) ?? .null
        notice=(try? await noticeRequest["notice"].string) ?? ""
        featured=(try? await masterpieceRequest.array.map {Video($0)}) ?? []
        // 自己的空间：acc/info 没有头图时用 myinfo 补（网页版头图来源），兼容 top_photo_v2。
        if mid==selfMid {
            var mine:JSON = .null
            if let value=try? await BiliAPI.shared.myInfo() {
                mine=value
                if case .object(var map)=profile {
                    for key in ["top_photo","top_photo_v2"] where map[key]?.string.isEmpty != false && !value[key].string.isEmpty { map[key]=value[key] }
                    if map["top_photo"]?.string.isEmpty != false && !value["top_photo_v2"].string.isEmpty { map["top_photo"]=value["top_photo_v2"] }
                    profile = .object(map)
                }
            }
            dumpSpaceDebug(["profile":profile,"myinfo":mine,"mid":.number(Double(mid))])
        }
    }
    /// 头图：最新投稿优先；没有投稿的账号用收藏夹第一条；不随 tab 切换变化。
    func pinnedCover(mid:Int,selfMid:Int) async -> String {
        if let data=try? await BiliAPI.shared.request("/x/space/wbi/arc/search",["mid":"\(mid)","pn":"1","ps":"1","order":"pubdate"],signed:true),
           let pic=data["list"]["vlist"].array.first?["pic"].string,!pic.isEmpty {
            return Video.secure(pic)
        }
        guard mid==selfMid else { return "" }
        if let folders=try? await BiliAPI.shared.request("/x/v3/fav/folder/created/list-all",["up_mid":"\(mid)"]),
           let folder=folders["list"].array.first, folder["id"].int>0 {
            let id=folder["id"].int
            if let list=try? await BiliAPI.shared.request("/x/v3/fav/resource/list",["media_id":"\(id)","pn":"1","ps":"1","platform":"web"]),
               let cover=list["medias"].array.first?["cover"].string,!cover.isEmpty {
                return Video.secure(cover)
            }
        }
        return ""
    }
    func load(_ mid:Int,tab:CreatorTab,more append:Bool=false) async {
        if append && (loading || !more) {return}
        if !append {generation=UUID();videos=[];posts=[];collections=[];people=[];articles=[];audio=[];page=1;offset="";more=true;failure=nil}
        let ticket=generation;loading=true;defer{if ticket==generation {loading=false}}
        do {
            switch tab {
            case .home,.videos:
                let data=try await BiliAPI.shared.request("/x/space/wbi/arc/search",["mid":"\(mid)","pn":"\(page)","ps":"30","order":"pubdate","tid":"\(category)"],signed:true)
                guard ticket==generation else{return}
                videos += data["list"]["vlist"].array.map {Video($0)}
                if case .object(let map)=data["list"]["tlist"] {categories=map.values.sorted{$0["tid"].int<$1["tid"].int}}
                more=videos.count<data["page"]["count"].int
            case .dynamic:
                let data=try await BiliAPI.shared.request("/x/polymer/web-dynamic/v1/feed/space",["host_mid":"\(mid)","offset":offset])
                guard ticket==generation else{return}
                posts += data["items"].array;offset=data["offset"].string;more=data["has_more"].bool
            case .collections:
                let data=try await BiliAPI.shared.creatorCollections(mid,page:page)
                guard ticket==generation else{return}
                collections += data["items_lists"]["seasons_list"].array.map {CreatorCollection($0,mid:mid,series:false)} + data["items_lists"]["series_list"].array.map {CreatorCollection($0,mid:mid,series:true)}
                more=collections.count<data["items_lists"]["page"]["total"].int
            case .favorites:
                if folders.isEmpty {
                    folders=try await BiliAPI.shared.request("/x/v3/fav/folder/created/list-all",["up_mid":"\(mid)"])["list"].array
                }
                if folder==0 {folder=folders.first?["id"].int ?? 0}
                guard ticket==generation else{return}
                if folder>0 {let data=try await BiliAPI.shared.request("/x/v3/fav/resource/list",["media_id":"\(folder)","pn":"\(page)","ps":"20","platform":"web"]);guard ticket==generation else{return};videos += data["medias"].array.map {Video($0)};more=data["has_more"].bool}else{more=false}
            case .bangumi,.cinema:
                let data=try await BiliAPI.shared.request("/x/space/bangumi/follow/list",["vmid":"\(mid)","type":tab == .bangumi ? "1":"2","pn":"\(page)","ps":"20"])
                guard ticket==generation else{return}
                videos += data["list"].array.map {Video(season:$0)};more=videos.count<data["total"].int
            case .following,.fans:
                let data=try await BiliAPI.shared.request(tab == .following ? "/x/relation/followings":"/x/relation/followers",["vmid":"\(mid)","pn":"\(page)","ps":"30","order":"desc"])
                guard ticket==generation else{return}
                people += data["list"].array.map(Creator.init);more=people.count<data["total"].int
            case .articles:
                let data=try await BiliAPI.shared.request("/x/space/article",["mid":"\(mid)","pn":"\(page)","ps":"20","sort":"publish_time"])
                guard ticket==generation else{return};articles += data["articles"].array;more=articles.count<data["count"].int
            case .audio:
                let data=try await BiliAPI.shared.request("/audio/music-service/web/song/upper",["uid":"\(mid)","pn":"\(page)","ps":"20","order":"1"])
                guard ticket==generation else{return};audio += data["data"].array;more=page<data["pageCount"].int
            case .about:more=false
            }
            page += 1
        } catch {if ticket==generation {failure=error.localizedDescription;more=false}}
    }
}
struct CreatorHomeView:View {
    let creator:Creator
    var isRoot=false
    @Environment(AccountSession.self) private var account
    @Environment(WindowPresentation.self) private var presentation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var model=CreatorModel()
    @State private var tab=CreatorTab.home
    @State private var following=false
    @State private var busy=false
    @State private var login=false
    @State private var verification=false
    @State private var message:String?
    @State private var viewport=CGSize(width:1000,height:800)
    @State private var headerPin=""
    @State private var headerPinResolved=false
    private var name:String {model.profile["name"].string.isEmpty ? creator.name:model.profile["name"].string}
    private var avatar:String {model.profile["face"].string.isEmpty ? creator.avatar:model.profile["face"].string}
    /// 头图优先用 UP 空间顶图；拿不到时退到代表作封面或头像，避免出现空白占位。
    /// 只用 UP 空间头图；拿不到就留空（不拿头像/封面冒充头图）。
    /// 只有极宽横幅可用时不做整图展示，仅用它取色。
    private var usesWideBanner:Bool { !bannerSource.isEmpty && headerImage == bannerSource }
    private var heroHeight: CGFloat { viewport.width * 9 / 16 }
    private var contentHeaderHeight:CGFloat { usesWideBanner ? 168:heroHeight }
    /// 头图优先用代表作/最新投稿的 16:9 封面（比 1280×200 横幅好排版），没有才退回空间横幅。
    private var headerImage:String {
        if !headerPin.isEmpty { return headerPin }
        return bannerSource
    }
    private var bannerSource:String {
        // top_photo_v2 是对象：l_img 为绝对地址；top_photo 可能是 "bfs/..." 相对路径。
        let v2=model.profile["top_photo_v2"]
        let absolute=v2["l_img"].string.isEmpty ? v2["l_200h_img"].string:v2["l_img"].string
        if !absolute.isEmpty { return absolute }
        return model.profile["top_photo"].string
    }
    private var loadKey:String {"\(tab.rawValue)|\(model.category)|\(model.folder)"}
    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:0,pinnedViews:[.sectionHeaders]) {
                header
                Section {
                    VStack(alignment:.leading,spacing:26) {content}.padding(32)
                } header:{
                    ScrollView(.horizontal) {HStack(spacing:8) {ForEach(CreatorTab.allCases) {item in Button {tab=item} label:{Text(item.rawValue).font(.system(size:13,weight:tab==item ? .semibold:.regular)).padding(.horizontal,14).padding(.vertical,9).background(tab==item ? Color.primary.opacity(0.09):.clear,in:.capsule)}.buttonStyle(.plain)}}}.scrollIndicators(.hidden).shelfBleed(22).padding(.vertical,12).background(.bar)
                }
            }
        }.ignoresSafeArea(edges:.top)
            .onGeometryChange(for:CGSize.self) {$0.size} action:{viewport=$0}
            .onScrollGeometryChange(for:Bool.self) {$0.contentOffset.y<contentHeaderHeight-65} action:{_,value in presentation.toolbarOverCover=value}
            .navigationTitle(presentation.immersive || presentation.toolbarOverCover ? "":name).navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement:.navigation) {if !presentation.immersive,!isRoot {Button {dismiss()} label:{Image(systemName:"chevron.left")}.help("返回上一页")}}
                ToolbarItem(placement:.primaryAction) {if !presentation.immersive {ShareLink(item:URL(string:"https://space.bilibili.com/\(creator.mid)")!) {Image(systemName:"square.and.arrow.up")}}}
            }
                        .task(id:creator.mid) {
                            presentation.toolbarOverCover=true
                            async let pin=model.pinnedCover(mid:creator.mid,selfMid:account.mid)
                            await model.header(creator.mid,selfMid:account.mid)
                            let cover=await pin
                            headerPin=cover
                            withAnimation(.easeOut(duration:0.25)) { headerPinResolved=true }
                            if let relation=try? await BiliAPI.shared.request("/x/relation",["fid":"\(creator.mid)"]) {following=[2,6].contains(relation["attribute"].int)}
                        }
            .task(id:loadKey) {await model.load(creator.mid,tab:tab)}
            .sheet(isPresented:$login) {LoginSheet().environment(account)}
            .sheet(isPresented:$verification) {OfficialVerificationSheet(url:URL(string:"https://space.bilibili.com/\(creator.mid)/upload/video")!,completed:{Task {await model.load(creator.mid,tab:tab)}}).environment(account)}
    }
    private var liveVideo:Video? {
        let room=model.profile["live_room"]
        guard room["roomid"].int>0 else {return nil}
        return Video(room:.object(["roomid":room["roomid"],"title":.string(room["title"].string.isEmpty ? name+"的直播间":room["title"].string),"uid":.number(Double(creator.mid)),"uname":.string(name),"user_cover":room["cover"]]))
    }
    private var header:some View {
        Group {
            if !headerPinResolved {
                Rectangle().fill(.quaternary.opacity(0.25))
                    .frame(height:heroHeight)
                    .overlay { ProgressView().controlSize(.small) }
                    .transition(.opacity)
            } else if !headerImage.isEmpty,!usesWideBanner {
                GeometryReader { geometry in
                    profileRow
                        .padding(.horizontal, 32)
                        .padding(.bottom, 38)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .background {
                            hero
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .backgroundExtensionEffect()
                        }
                }.frame(height:heroHeight)
            } else {
                profileRow.padding(.horizontal,32).padding(.vertical,24)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color.black.opacity(0.22))
            }
        }
        .frame(height:headerPinResolved ? contentHeaderHeight:heroHeight,alignment:.top)
        .animation(.easeOut(duration:0.25),value:headerPinResolved)
    }
    /// 封面等比铺满，资料行压在底部渐进模糊区域上。
    private var hero:some View {
        ZStack {
            CoverImage(source:Video.secure(headerImage),width:1920,showsPlaceholderIcon:false)
            CoverImage(source:Video.secure(headerImage),width:1200,showsPlaceholderIcon:false)
                .blur(radius:8)
                .mask(LinearGradient(stops:[.init(color:.clear,location:0.52),.init(color:.white,location:0.7)],startPoint:.top,endPoint:.bottom))
            CoverImage(source:Video.secure(headerImage),width:1200,showsPlaceholderIcon:false)
                .blur(radius:22)
                .mask(LinearGradient(stops:[.init(color:.clear,location:0.66),.init(color:.white,location:0.84)],startPoint:.top,endPoint:.bottom))
            CoverImage(source:Video.secure(headerImage),width:1200,showsPlaceholderIcon:false)
                .blur(radius:48)
                .mask(LinearGradient(stops:[.init(color:.clear,location:0.78),.init(color:.white,location:0.98)],startPoint:.top,endPoint:.bottom))
            LinearGradient(stops:[.init(color:.clear,location:0.45),.init(color:.black.opacity(0.5),location:0.85),.init(color:.black.opacity(0.6),location:1)],startPoint:.top,endPoint:.bottom)
        }
    }
    private var profileRow:some View {
        HStack(alignment:.bottom,spacing:22) {
            AvatarView(source:avatar,size:86)
            VStack(alignment:.leading,spacing:9) {
                HStack(spacing:10) {Text(name).font(.system(size:30,weight:.bold)).lineLimit(1).minimumScaleFactor(0.7);if model.profile["official"]["type"].int>=0,!model.profile["official"]["title"].string.isEmpty {Image(systemName:"checkmark.seal.fill").foregroundStyle(.blue)};if model.profile["vip"]["status"].int==1 {Text("大会员").font(.caption.weight(.medium)).foregroundStyle(.pink)}}
                Text(model.profile["sign"].string.isEmpty ? creator.signature:model.profile["sign"].string).font(.system(size:13)).lineSpacing(4).lineLimit(2).foregroundStyle(.white.opacity(0.78))
                HStack(spacing:20) {
                    stat("关注",model.stats["following"],tab:.following)
                    stat("粉丝",model.stats["follower"],tab:.fans)
                    stat("获赞",model.upstat["likes"])
                    if viewport.width>980 {stat("播放",model.upstat["archive"]["view"])}
                }
            }
            Spacer(minLength:8)
            VStack(spacing:10) {Button(following ? "已关注":"关注") {follow()}.buttonStyle(.glassProminent).buttonBorderShape(.capsule).disabled(busy);if let liveVideo,viewport.width>860 {NavigationLink(value:AppRoute.video(liveVideo)) {Text("直播间")}.buttonStyle(.glass)}}
        }.foregroundStyle(.white)
    }
    private func stat(_ title:String,_ value:JSON,tab target:CreatorTab?=nil)->some View {
        Button {if let target {tab=target}} label:{VStack(alignment:.leading,spacing:3) {Text(value.string.isEmpty ? "—":value.int.formatted()).font(.system(size:16,weight:.semibold));Text(title).font(.caption).foregroundStyle(.white.opacity(0.7))}}.buttonStyle(.plain).disabled(target==nil)
    }
    @ViewBuilder private var content:some View {
        if let message {Text(message).font(.callout).foregroundStyle(.secondary)}
        if let failure=model.failure {ContentUnavailableView {Label("暂时无法读取",systemImage:"lock.rectangle")} description:{Text(failure+"。内容可能未公开，或当前接口访问受限。")} actions:{Button("重试") {Task {await model.load(creator.mid,tab:tab)}};Button("完成官方验证") {verification=true}}.frame(maxWidth:.infinity)}
        switch tab {
        case .home,.videos:
            if tab == .home {
                if !model.notice.isEmpty {VStack(alignment:.leading,spacing:8) {Label("公告",systemImage:"megaphone").font(.headline);Text(model.notice).font(.callout).lineSpacing(5).textSelection(.enabled)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.25),in:.rect(cornerRadius:14))}
                if model.profile["live_room"]["liveStatus"].int==1,let liveVideo {Text("正在直播").font(.title2.bold());NavigationLink(value:AppRoute.video(liveVideo)) {VideoCard(video:liveVideo).frame(maxWidth:440)}.buttonStyle(.plain)}
                if !model.featured.isEmpty {Text("代表作").font(.title2.bold());VideoShelf(videos:model.featured)}
            }
            HStack {Text(tab == .home ? "最新投稿":"视频投稿").font(.title2.bold());Spacer();if !model.categories.isEmpty {Picker("分区",selection:Binding(get:{model.category},set:{model.category=$0})) {Text("全部视频").tag(0);ForEach(model.categories.indices,id:\.self) {i in Text(model.categories[i]["name"].string).tag(model.categories[i]["tid"].int)}}.fixedSize()}}
            videoGrid(model.videos)
        case .dynamic:ForEach(model.posts.indices,id:\.self) {index in NativeDynamicCard(post:model.posts[index])}
        case .collections:
            LazyVGrid(columns:[GridItem(.adaptive(minimum:230,maximum:360),spacing:20)],spacing:24) {
                ForEach(model.collections) {collection in NavigationLink(value:AppRoute.collection(collection)) {VStack(alignment:.leading,spacing:10) {Thumbnail(source:collection.cover).clipShape(.rect(cornerRadius:12));Text(collection.title).font(.headline).lineLimit(2).frame(height:40,alignment:.topLeading);Text(collection.series ? "视频列表":"合集").font(.caption).foregroundStyle(.secondary)}}.buttonStyle(.plain)}
            }
        case .favorites:
            if !model.folders.isEmpty {Picker("收藏夹",selection:Binding(get:{model.folder},set:{model.folder=$0})) {ForEach(model.folders.indices,id:\.self) {i in Text(model.folders[i]["title"].string).tag(model.folders[i]["id"].int)}}.frame(maxWidth:400)}
            videoGrid(model.videos)
        case .bangumi,.cinema:videoGrid(model.videos)
        case .following,.fans:
            ForEach(model.people) {person in NavigationLink(value:AppRoute.creator(person)) {HStack(spacing:14) {AvatarView(source:person.avatar,size:50);VStack(alignment:.leading,spacing:5) {Text(person.name).font(.headline);Text(person.signature).font(.caption).foregroundStyle(.secondary).lineLimit(2)};Spacer();Image(systemName:"chevron.right").foregroundStyle(.tertiary)}.padding(.vertical,10)}.buttonStyle(.plain)}
        case .articles:ForEach(model.articles.indices,id:\.self) {i in ArticleResultRow(article:model.articles[i])}
        case .audio:
            ForEach(model.audio.indices,id:\.self) {i in let item=model.audio[i];Link(destination:URL(string:"https://www.bilibili.com/audio/au\(item["id"].int)")!) {HStack(spacing:14) {CoverImage(source:item["cover"].string,width:128).frame(width:64,height:64).clipped().clipShape(.rect(cornerRadius:10));VStack(alignment:.leading,spacing:6) {Text(item["title"].string).font(.headline);Text(item["author"].string).font(.caption).foregroundStyle(.secondary)};Spacer();Image(systemName:"music.note")}}.buttonStyle(.plain)}
        case .about:
            Form {
                LabeledContent("UID",value:String(creator.mid));LabeledContent("昵称",value:name)
                if model.profile["level"].int>0 {LabeledContent("等级",value:"Lv.\(model.profile["level"].int)")}
                if !model.profile["official"]["title"].string.isEmpty {LabeledContent("认证",value:model.profile["official"]["title"].string)}
                if !model.profile["official"]["desc"].string.isEmpty {Text(model.profile["official"]["desc"].string).font(.callout)}
                Text(model.profile["sign"].string).textSelection(.enabled)
                if !model.profile["school"]["name"].string.isEmpty {LabeledContent("学校",value:model.profile["school"]["name"].string)}
                if !model.profile["fans_medal"]["medal"]["medal_name"].string.isEmpty {LabeledContent("粉丝勋章",value:model.profile["fans_medal"]["medal"]["medal_name"].string+" · Lv.\(model.profile["fans_medal"]["medal"]["level"].int)")}
                if !model.profile["nameplate"]["name"].string.isEmpty {LabeledContent("成就",value:model.profile["nameplate"]["name"].string)}
                if let warning=model.headerFailure {Text("部分资料未能读取："+warning).font(.caption).foregroundStyle(.secondary)}
            }.formStyle(.grouped).frame(minHeight:300)
        }
        if model.loading {ProgressView("正在加载…").frame(maxWidth:.infinity)}
        if !model.loading,model.failure==nil,tab != .about,model.videos.isEmpty,model.posts.isEmpty,model.collections.isEmpty,model.people.isEmpty,model.articles.isEmpty,model.audio.isEmpty {ContentUnavailableView("暂无公开内容",systemImage:"rectangle.stack",description:Text("该栏目暂无内容，或 UP 主未公开此信息。")).frame(maxWidth:.infinity)}
        if model.more,!model.loading {Button("加载更多") {Task {await model.load(creator.mid,tab:tab,more:true)}}.buttonStyle(.glass).frame(maxWidth:.infinity)}
    }
    private func videoGrid(_ videos:[Video])->some View {LazyVGrid(columns:[GridItem(.adaptive(minimum:220,maximum:360),spacing:20)],spacing:26) {ForEach(videos) {video in NavigationLink(value:AppRoute.video(video)) {VideoCard(video:video)}.buttonStyle(.plain)}}}
    private func follow() {
        guard account.loggedIn else {login=true;return};guard !busy else{return};busy=true
        Task {defer{busy=false};do {_=try await BiliAPI.shared.request("/x/relation/modify",["fid":"\(creator.mid)","act":following ? "2":"1","re_src":"11"],post:true);following.toggle()}catch{message=error.localizedDescription}}
    }
}
struct NativeDynamicCard:View {
    let post:JSON
    var body:some View {
        let author=post["modules"]["module_author"],dynamic=post["modules"]["module_dynamic"],stat=post["modules"]["module_stat"]
        VStack(alignment:.leading,spacing:16) {
            NavigationLink(value:AppRoute.creator(Creator(mid:author["mid"].int,name:author["name"].string,avatar:author["face"].string))) {HStack(spacing:12) {AvatarView(source:author["face"].string,size:40);VStack(alignment:.leading,spacing:4) {Text(author["name"].string).font(.headline);Text(author["pub_time"].string).font(.caption).foregroundStyle(.secondary)}}}.buttonStyle(.plain)
            Text(dynamic["desc"]["text"].string.isEmpty ? dynamic["major"]["opus"]["summary"]["text"].string:dynamic["desc"]["text"].string).font(.system(size:14)).lineSpacing(5).textSelection(.enabled)
            if !dynamic["major"]["archive"]["bvid"].string.isEmpty {
                let archive=dynamic["major"]["archive"]
                let video=Video(.object(["bvid":archive["bvid"],"aid":archive["aid"],"pic":archive["cover"],"title":archive["title"],"duration":archive["duration_text"],"owner":author]))
                NavigationLink(value:AppRoute.video(video)) {VideoCard(video:video).frame(maxWidth:420)}.buttonStyle(.plain)
            }
            let pictures=dynamic["major"]["draw"]["items"].array.isEmpty ? dynamic["major"]["opus"]["pics"].array:dynamic["major"]["draw"]["items"].array
            if !pictures.isEmpty {LazyVGrid(columns:[GridItem(.adaptive(minimum:150,maximum:240))],spacing:10) {ForEach(Array(pictures.prefix(9).enumerated()),id:\.offset) {_,picture in Thumbnail(source:Video.secure(picture["src"].string.isEmpty ? picture["url"].string:picture["src"].string)).clipShape(.rect(cornerRadius:10))}}}
            HStack(spacing:24) {Label(stat["forward"]["count"].int.formatted(),systemImage:"arrowshape.turn.up.right");Label(stat["comment"]["count"].int.formatted(),systemImage:"bubble");Label(stat["like"]["count"].int.formatted(),systemImage:"hand.thumbsup")}.font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth:920,alignment:.leading).background(.quaternary.opacity(0.25),in:.rect(cornerRadius:18))
    }
}
struct CreatorCollectionView:View {
    let collection:CreatorCollection
    @Environment(WindowPresentation.self) private var presentation
    @State private var videos:[Video]=[]
    @State private var page=1
    @State private var loading=false
    @State private var more=true
    @State private var failure:String?
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:24) {Text(collection.title).font(.largeTitle.bold());if let failure {Text(failure).foregroundStyle(.red)};LazyVGrid(columns:[GridItem(.adaptive(minimum:220,maximum:360),spacing:20)],spacing:26) {ForEach(videos) {video in NavigationLink(value:AppRoute.video(video)) {VideoCard(video:video)}.buttonStyle(.plain)}};if loading {ProgressView()};if more {Button("加载更多") {Task {await load()}}.buttonStyle(.glass).disabled(loading)}}.padding(32)}.navigationTitle(collection.title).task {presentation.toolbarOverCover=false;await load()}
    }
    private func load() async {
        guard !loading,more else{return};loading=true;defer{loading=false}
        do {let data=try await BiliAPI.shared.collectionVideos(collection,page:page);let items=data["archives"].array.map {Video($0)};let ids=Set(videos.map(\.id));videos += items.filter{!ids.contains($0.id)};page += 1;more=items.count>=30}catch{failure=error.localizedDescription;more=false}
    }
}
