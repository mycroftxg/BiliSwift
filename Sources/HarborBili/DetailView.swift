import SwiftUI
import HarborCore

struct DetailView:View {
    let video:Video
    @Environment(AccountSession.self) private var account
    @Environment(LocalLibrary.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(AppPreferences.self) private var preferences
    @Environment(WindowPresentation.self) private var presentation
    @State private var model=DetailModel()
    @State private var cid=0
    @State private var login=false
    @State private var favorite=false
    @State private var coinConfirm=false
    @State private var commentConfirm=false
    @State private var comment=""
    @State private var dm=""
    @State private var postingDM=false
    @State private var viewport=CGSize(width:1000,height:800)
    @State private var descExpanded=false
    private var heroHeight:CGFloat { viewport.width * 9 / 16 }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:0) {
                detailHero
                VStack(alignment:.leading,spacing:26) {
                if model.loading { ProgressView("正在获取详情…") }
                actions
                if let notice=model.notice { Label(notice,systemImage:"checkmark.circle").font(.callout).foregroundStyle(.secondary) }
                if let error=model.error { VStack(alignment:.leading) { Text(error).foregroundStyle(.red).textSelection(.enabled);Button("重新加载详情") { Task { await model.load(video) } } } }
                if model.pages.count>1 {
                    HStack(alignment:.firstTextBaseline,spacing:10) {
                        Text("选集").font(.title2.bold())
                        Text("共 \(model.pages.count) P").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing:12) {
                            ForEach(model.pages) { episode in
                                EpisodeCard(episode:episode,playing:episode.cid==cid) { Task { await play(episode) } }
                            }
                        }.padding(.vertical,2)
                    }.scrollIndicators(.hidden).shelfBleed(36)
                }
                if model.collectionEpisodes.count>1 {
                    HStack(alignment:.firstTextBaseline,spacing:10) {
                        Text("合集 · \(model.collectionTitle)").font(.title2.bold()).lineLimit(1)
                        Text("\(model.collectionEpisodes.count) 集").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing:12) {
                            ForEach(model.collectionEpisodes) { episode in
                                Button { Task { await playCollection(episode) } } label:{
                                    VStack(alignment:.leading,spacing:6) {
                                        Thumbnail(source:episode.cover).frame(width:190,height:107).clipShape(.rect(cornerRadius:10))
                                        Text(episode.title).font(.system(size:12,weight:.medium)).lineLimit(1).frame(width:190,alignment:.leading)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }.padding(.vertical,2)
                    }.scrollIndicators(.hidden).shelfBleed(36)
                }
                if !model.related.isEmpty {
                    Text("相关推荐").font(.title2.bold())
                    VideoShelf(videos:model.related,cardWidth:250)
                }
                comments
                }.padding(36)
            }
        }.onGeometryChange(for:CGSize.self) { $0.size } action:{viewport=$0}.ignoresSafeArea(edges:.top).navigationTitle(presentation.immersive || presentation.toolbarOverCover ? "":video.title).navigationBarBackButtonHidden(true)
            .onScrollGeometryChange(for:Bool.self) { $0.contentOffset.y<heroHeight-65 } action:{_,over in presentation.toolbarOverCover=over}
            .toolbar {
                ToolbarItem(placement:.navigation) { if !presentation.immersive { Button { presentation.exitFullScreen();dismiss() } label:{ Image(systemName:"chevron.left") }.help("返回上一页") } }
                ToolbarItem(placement:.primaryAction) { if !presentation.immersive { ShareLink(item:URL(string:"https://www.bilibili.com/video/\(video.bvid)")!) { Image(systemName:"square.and.arrow.up") } } }
            }
            .task(id:video.bvid) { presentation.toolbarOverCover=true;await model.load(video);if preferences.values.autoPlay,playback.video?.bvid != video.bvid { await playFirst() } }
            .sheet(isPresented:$login) { LoginSheet().environment(account) }
            .sheet(isPresented:$favorite) { FavoriteSheet(video:video).environment(account) }
            .confirmationDialog("向这个视频投 1 枚硬币？",isPresented:$coinConfirm,titleVisibility:.visible) {
                Button("确认投币") { Task { _=await model.perform("/x/web-interface/coin/add",["bvid":video.bvid,"multiply":"1","select_like":"0"],success:"已投币") } }
            }
            .alert("发布评论？",isPresented:$commentConfirm) {
                Button("取消",role:.cancel) {}
                Button("发布") { Task { await sendComment() } }
            } message:{ Text(comment) }
    }
    private var actions:some View {
        HStack(spacing:12) {
            Button { requireLogin { Task {
                if await model.perform("/x/web-interface/archive/like",["bvid":video.bvid,"like":model.liked ? "2":"1"],success:model.liked ? "已取消点赞":"已点赞") { model.liked.toggle() }
            } } } label:{ Label(model.liked ? "已点赞":"点赞",systemImage:model.liked ? "hand.thumbsup.fill":"hand.thumbsup") }
            Button { requireLogin { coinConfirm=true } } label:{ Label("投币",systemImage:"circle") }
            Button { requireLogin { favorite=true } } label:{ Label("收藏",systemImage:"star") }
            Button { requireLogin { Task { _=await model.perform("/x/v2/history/toview/add",["bvid":video.bvid],success:"已加入稍后再看") } } } label:{ Label("稍后再看",systemImage:"text.badge.plus") }
            Button { requireLogin { Task { _=await model.perform("/x/relation/modify",["fid":"\(video.mid)","act":"1","re_src":"11"],success:"已关注 UP 主") } } } label:{ Label("关注",systemImage:"person.badge.plus") }
            ShareLink(item:URL(string:"https://www.bilibili.com/video/\(video.bvid)")!) { Image(systemName:"square.and.arrow.up") }
        }.buttonStyle(.glass).buttonBorderShape(.capsule).disabled(model.busy)
    }
    private var comments:some View {
        VStack(alignment:.leading,spacing:24) {
            HStack(alignment:.firstTextBaseline,spacing:10) {
                Text("评论").font(.system(size:25,weight:.bold))
                if model.detail["stat"]["reply"].int>0 { Text(model.detail["stat"]["reply"].int,format:.number).font(.subheadline).foregroundStyle(.secondary) }
            }
            HStack(alignment:.top,spacing:14) {
                AvatarView(source:account.avatar,size:40)
                VStack(alignment:.trailing,spacing:10) {
                    TextField("分享你的想法…",text:$comment,axis:.vertical).font(.system(size:14)).lineLimit(2...6).textFieldStyle(.plain).padding(14).background(.quaternary.opacity(0.4),in:.rect(cornerRadius:14))
                    Button("发布评论") { requireLogin { commentConfirm=true } }.buttonStyle(.glassProminent).disabled(model.busy || comment.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }
            }
            if model.comments.isEmpty { Text("暂无评论，或评论尚未加载。").font(.callout).foregroundStyle(.secondary) }
            LazyVStack(alignment:.leading,spacing:0) {
                ForEach(model.comments.indices,id:\.self) { index in
                    CommentRow(entry:model.comments[index],aid:video.aid,onLike:{ entry in
                        requireLogin { Task { _=await model.perform("/x/v2/reply/action",["oid":"\(video.aid)","type":"1","rpid":entry["rpid"].string,"action":"1"],success:"已赞评论") } }
                    },onLogin:{login=true}).id(model.comments[index]["rpid"].string)
                }
            }
            if !model.comments.isEmpty,model.hasMoreComments { Button("加载更多评论") { Task { await model.moreComments(video) } }.buttonStyle(.glass).disabled(model.busy) }
        }.frame(maxWidth:920,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
    }
    private var detailHero:some View {
        GeometryReader { geometry in
            ZStack(alignment:.bottomLeading) {
                let textWidth=max(220,min(650,geometry.size.width-88))
                CoverImage(source:video.cover,width:1920).frame(width:geometry.size.width,height:heroHeight).clipped().backgroundExtensionEffect()
                LinearGradient(colors:[.black.opacity(0.35),.clear],startPoint:.top,endPoint:.bottom)
                LinearGradient(stops:[.init(color:.clear,location:0.15),.init(color:.black.opacity(0.3),location:0.45),.init(color:.black.opacity(0.9),location:1)],startPoint:.top,endPoint:.bottom)
                LinearGradient(colors:[.black.opacity(0.35),.clear],startPoint:.leading,endPoint:.trailing)
                VStack(alignment:.leading,spacing:15) {
                    if heroHeight>=450,!model.detail["tname"].string.isEmpty { Text(model.detail["tname"].string).font(.caption.weight(.semibold)).padding(.horizontal,10).padding(.vertical,5).glassEffect(.regular,in:.capsule) }
                    Text(video.title).font(.system(size:max(24,min(36,geometry.size.width*0.036)),weight:.bold)).lineLimit(heroHeight<420 ? 2:3).frame(maxWidth:textWidth,alignment:.leading)
                    HStack(spacing:8) { NavigationLink(value:AppRoute.creator(Creator(mid:video.mid,name:video.author,avatar:model.detail["owner"]["face"].string))) { HStack(spacing:8) {AvatarView(source:model.detail["owner"]["face"].string,size:24);Text(video.author).font(.subheadline.weight(.medium))} }.buttonStyle(.plain);Text("·  "+video.viewLabel).font(.subheadline).foregroundStyle(.white.opacity(0.7)) }
                    Text(model.detail["desc"].string).font(.system(size:14)).lineSpacing(4)
                        .lineLimit(heroHeight<450 ? 1:2)
                        .frame(maxWidth:textWidth,alignment:.leading)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(.snappy(duration:0.2)) { descExpanded.toggle() } }
                        .overlay(alignment:.bottomLeading) {
                            if descExpanded,model.detail["desc"].string.count>30 {
                                DescriptionPopover(text:model.detail["desc"].string,width:min(textWidth,560)) {
                                    withAnimation(.snappy(duration:0.2)) { descExpanded=false }
                                }
                                .offset(y:-12)
                                .transition(.opacity.combined(with:.scale(scale:0.96,anchor:.bottomLeading)))
                            }
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .animation(.snappy(duration:0.2),value:descExpanded)
                        .help(model.detail["desc"].string)
                    HStack(spacing:14) {
                        Button { Task { await playFirst() } } label:{ Label(playback.video?.bvid==video.bvid ? "继续播放":"播放视频",systemImage:"play.fill").font(.headline).padding(.horizontal,28).padding(.vertical,12) }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.white).foregroundStyle(.black).disabled(model.loading)
                        Button { requireLogin { favorite=true } } label:{ Image(systemName:"plus").font(.title3).frame(width:38,height:38) }.buttonStyle(.glass).buttonBorderShape(.circle).help("收藏视频")
                        if model.pages.count>1 { Text("共 \(model.pages.count) 集").font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    }.padding(.top,4)
                }.foregroundStyle(.white).padding(.horizontal,40).padding(.bottom,44)
            }.environment(\.colorScheme,.dark)
        }.frame(height:heroHeight)
    }
    private var seriesEpisodes:[Episode] {
        let collection=model.collectionEpisodes
        guard collection.count>1 else { return model.pages }
        return collection.map { ep in
            let video=Video(.object(["bvid":.string(ep.bvid),"aid":.number(0),"title":.string(ep.title),"pic":.string(ep.cover),
                                     "author":.string(self.video.author),"mid":.number(Double(self.video.mid)),"duration":.string("")]))
            return Episode(video:video,cid:ep.cid,title:ep.title,page:ep.index+1)
        }
    }
    private func requireLogin(_ action:()->Void) { if account.loggedIn { action() } else { login=true } }
    private func playFirst() async {
        if model.pages.isEmpty,model.collectionEpisodes.isEmpty { await model.load(video) }
        let all=seriesEpisodes
        if !model.collectionEpisodes.isEmpty,let current=all.first(where:{$0.video?.bvid==video.bvid}) ?? all.first {
            await play(current);return
        }
        guard let first=model.pages.first(where:{$0.cid==playback.cid && playback.video?.bvid==video.bvid}) ?? model.pages.first else { model.error="此内容未返回可播放分集，请在官方网页检查。";return }
        await play(first)
    }
    private func play(_ episode:Episode) async {
        cid=episode.cid;presentation.immersive=true
        let target=episode.video ?? video
        if playback.video?.bvid==target.bvid,playback.cid==episode.cid,playback.error==nil,playback.manifest != nil { playback.player.playImmediately(atRate:playback.rate);return }
        await playback.open(video:target,cid:episode.cid,library:library,episodes:seriesEpisodes)
    }
    private func playCollection(_ episode:CollectionEpisode) async {
        guard let mapped=seriesEpisodes.first(where:{$0.cid==episode.cid}) ?? seriesEpisodes.first(where:{$0.video?.bvid==episode.bvid}) else { return }
        await play(mapped)
    }
    private func sendComment() async {
        if await model.perform("/x/v2/reply/add",["oid":"\(video.aid)","type":"1","message":comment,"plat":"1"],success:"评论已提交") { comment="";await model.load(video) }
    }
    private func sendDanmaku() async {
        guard account.loggedIn else { login=true;return };guard !postingDM else { return }
        postingDM=true;defer { postingDM=false }
        let text=dm.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.count<=100 else { model.error="弹幕请控制在 100 字以内。";return }
        if await model.perform("/x/v2/dm/post",["type":"1","oid":"\(cid)","msg":text,"progress":"\(Int(playback.seconds*1000))","color":"16777215","fontsize":"25","pool":"0","mode":"1","rnd":"\(Int(Date().timeIntervalSince1970*1000000))"],success:"弹幕已提交") { dm="" }
    }
}

private struct DescHeightKey:PreferenceKey { static let defaultValue:CGFloat=0;static func reduce(value:inout CGFloat,nextValue:()->CGFloat){value=max(value,nextValue())} }

struct DescriptionPopover:View {
    let text:String
    let width:CGFloat
    var onClose:()->Void
    @State private var textHeight:CGFloat=200
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("简介").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button { onClose() } label:{ Image(systemName:"xmark").font(.system(size:11,weight:.semibold)).frame(width:22,height:22) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("收起简介")
            }
            ScrollView(.vertical) {
                Text(text).font(.system(size:13)).lineSpacing(3).foregroundStyle(.white)
                    .lineLimit(nil).fixedSize(horizontal:false,vertical:true).multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .background { GeometryReader { proxy in Color.clear.preference(key:DescHeightKey.self,value:proxy.size.height) } }
            }
            .scrollIndicators(.visible)
            .frame(height:min(max(textHeight,60),320))
            .onPreferenceChange(DescHeightKey.self) { textHeight=$0 }
        }
        .padding(14)
        .frame(width:width)
        .glassEffect(.regular.tint(.black.opacity(0.3)),in:.rect(cornerRadius:14))
        .environment(\.colorScheme,.dark)
    }
}

struct EpisodeCard:View {
    let episode:Episode
    let playing:Bool
    var action:()->Void
    @State private var hovering=false
    var body:some View {
        Button { action() } label:{
            HStack(spacing:11) {
                ZStack {
                    RoundedRectangle(cornerRadius:9,style:.continuous)
                        .fill(playing ? AnyShapeStyle(Color.accentColor.opacity(0.9)):AnyShapeStyle(.quaternary))
                        .frame(width:42,height:42)
                    if playing { Image(systemName:"waveform").font(.system(size:16,weight:.semibold)).foregroundStyle(.white) }
                    else { Text("P\(episode.page)").font(.system(size:13,weight:.bold)).foregroundStyle(.secondary) }
                }
                VStack(alignment:.leading,spacing:3) {
                    Text(episode.title).font(.system(size:13,weight:.medium)).lineLimit(1).foregroundStyle(.primary)
                    Text(playing ? "正在播放":"P\(episode.page)").font(.caption2).foregroundStyle(playing ? Color.accentColor:.secondary)
                }
                Spacer(minLength:0)
            }
            .padding(.horizontal,12).padding(.vertical,10)
            .frame(width:236,alignment:.leading)
            .background(playing ? Color.accentColor.opacity(0.12):Color.primary.opacity(0.045),in:.rect(cornerRadius:13))
            .overlay { RoundedRectangle(cornerRadius:13,style:.continuous).strokeBorder(playing ? Color.accentColor.opacity(0.75):Color.primary.opacity(0.06),lineWidth:1) }
            .scaleEffect(hovering ? 1.02:1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering=$0 }
        .animation(.smooth(duration:0.16),value:hovering)
    }
}
