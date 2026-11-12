import SwiftUI
import HarborCore

struct SeasonDetailView:View {
    let video:Video
    @Environment(AppPreferences.self) private var preferences
    @Environment(AccountSession.self) private var account
    @Environment(LocalLibrary.self) private var library
    @Environment(PlaybackController.self) private var playback
    @Environment(WindowPresentation.self) private var presentation
    @Environment(\.dismiss) private var dismiss
    @State private var detail:JSON = .null
    @State private var loading=false
    @State private var busy=false
    @State private var failure:String?
    @State private var login=false
    @State private var followed=false
    @State private var selected:JSON = .null
    @State private var comments:[JSON]=[]
    @State private var replying=false
    @State private var viewport=CGSize(width:1000,height:800)
    @State private var heroReady=false
    @State private var heroImage:NSImage?
    private var seasonID:Int { video.seasonID ?? 0 }
    private var title:String { detail["title"].string.isEmpty ? video.title:detail["title"].string }
    private var episodes:[JSON] { detail["episodes"].array }
    private var heroHeight:CGFloat { viewport.width * 9 / 16 }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:0) {
                GeometryReader { geometry in
                    ZStack(alignment:.bottomLeading) {
                        let textWidth=max(220,min(650,geometry.size.width-88))
                        Group {
                            if let heroImage {
                                SeasonArtwork(image: heroImage)
                                    .transition(.opacity)
                            } else {
                                Rectangle().fill(.black)
                                    .overlay { if !heroReady { ProgressView().controlSize(.small).tint(.white) } }
                            }
                        }
                        .frame(width:geometry.size.width,height:heroHeight).clipped().backgroundExtensionEffect()
                        .animation(.easeOut(duration:0.3),value:heroReady)
                        LinearGradient(colors:[.clear,.black.opacity(0.9)],startPoint:.top,endPoint:.bottom)
                        LinearGradient(colors:[.black.opacity(0.3),.clear],startPoint:.leading,endPoint:.trailing)
                        VStack(alignment:.leading,spacing:16) {
                            Text(title).font(.system(size:max(24,min(36,geometry.size.width*0.036)),weight:.bold)).lineLimit(heroHeight<420 ? 2:3).frame(maxWidth:textWidth,alignment:.leading)
                            HStack(spacing:12) {
                                if detail["rating"]["score"].double>0 { Label(detail["rating"]["score"].double.formatted(),systemImage:"star.fill") }
                                Text(detail["new_ep"]["desc"].string.isEmpty ? video.author:detail["new_ep"]["desc"].string)
                            }.font(.subheadline).foregroundStyle(.white.opacity(0.8))
                            Text(detail["evaluate"].string).help(detail["evaluate"].string).font(.system(size:14)).lineSpacing(4).lineLimit(heroHeight<450 ? 1:3).frame(maxWidth:textWidth,alignment:.leading).foregroundStyle(.white.opacity(0.8))
                            HStack(spacing:14) {
                                Button { if let episode=episodes.first(where:{$0["id"].int==playback.video?.episodeID}) ?? episodes.first { play(episode) } } label:{ Label("播放",systemImage:"play.fill").font(.headline).padding(.horizontal,32).padding(.vertical,12) }.buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.white).foregroundStyle(.black).disabled(loading || episodes.isEmpty)
                                Button { follow() } label:{ Label(followed ? "已追番":"追番 / 追剧",systemImage:followed ? "checkmark":"plus") }.buttonStyle(.glass).buttonBorderShape(.capsule).disabled(busy)
                            }
                        }.foregroundStyle(.white).padding(.horizontal,40).padding(.bottom,44)
                    }.environment(\.colorScheme,.dark)
                }.frame(height:heroHeight)
                VStack(alignment:.leading,spacing:26) {
                    if loading { ProgressView("正在获取剧集…") }
                    if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                    if !episodes.isEmpty {
                        HStack { Text("选集").font(.title2.bold());Text("\(episodes.count) 集").font(.subheadline).foregroundStyle(.secondary) }
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:210,maximum:320),spacing:20)],alignment:.leading,spacing:24) {
                            ForEach(episodes.indices,id:\.self) { index in
                                let episode=episodes[index]
                                Button { play(episode) } label:{
                                    VStack(alignment:.leading,spacing:10) {
                                        Thumbnail(source:Video.secure(episode["cover"].string)).clipShape(.rect(cornerRadius:12))
                                        Text(episode["show_title"].string.isEmpty ? episode["title"].string+" "+episode["long_title"].string:episode["show_title"].string).font(.headline).lineLimit(2).frame(height:40,alignment:.topLeading)
                                        Text(episode["badge"].string.isEmpty ? "第 \(index+1) 集":episode["badge"].string).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !comments.isEmpty {
                        VStack(alignment:.leading,spacing:12) {
                            HStack { Text("本集评论").font(.title2.bold());Spacer();Button("写评论") { if account.loggedIn { replying=true } else { login=true } }.buttonStyle(.glass) }
                            ForEach(comments.indices,id:\.self) { index in CommentRow(entry:comments[index],aid:selected["aid"].int,onLike:{comment in like(comment)},onLogin:{login=true}).id(comments[index]["rpid"].string) }
                        }.frame(maxWidth:920,alignment:.leading)
                    }
                }.padding(36)
            }
        }.ignoresSafeArea(edges:.top)
            .onGeometryChange(for:CGSize.self) { $0.size } action:{viewport=$0}
            .onScrollGeometryChange(for:Bool.self) { $0.contentOffset.y<heroHeight-65 } action:{_,over in presentation.toolbarOverCover=over}
            .navigationTitle(presentation.immersive || presentation.toolbarOverCover ? "":title).navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement:.navigation) { if !presentation.immersive { Button { dismiss() } label:{ Image(systemName:"chevron.left") }.help("返回上一页") } }
                ToolbarItem(placement:.primaryAction) { if !presentation.immersive { ShareLink(item:URL(string:"https://www.bilibili.com/bangumi/play/ss\(seasonID)")!) { Image(systemName:"square.and.arrow.up") } } }
            }
            .task(id:seasonID) { await load() }
            .sheet(isPresented:$login) { LoginSheet().environment(account) }
            .sheet(isPresented:$replying) { ReplyComposer(aid:selected["aid"].int,root:"0",parent:"0",name:"本集").environment(account) }
    }
    private func load() async {
        presentation.toolbarOverCover=true;loading=true;defer {loading=false}
        do {
            detail=try await BiliAPI.shared.season(seasonID)
            let image = await TMDBPosters.shared.backdrop(for: video, detail: detail, token: preferences.values.tmdbToken)
            guard !Task.isCancelled else { return }
            heroImage = image
            heroReady=true
            followed=detail["user_status"]["follow"].int==1
            selected=episodes.first(where:{$0["id"].int==video.episodeID}) ?? episodes.first ?? .null
            if selected["aid"].int>0 { await loadComments(selected) }
        } catch { heroReady=true;failure=error.localizedDescription }
    }
    private func play(_ episode:JSON) {
        selected=episode
        let target=Video.episode(episode,seasonID:seasonID,seasonTitle:title)
        presentation.immersive=true
        if playback.video?.episodeID==target.episodeID,playback.manifest != nil,playback.error==nil {playback.player.playImmediately(atRate:playback.rate);return}
        let list=episodes.enumerated().map {index,item in Episode(video:Video.episode(item,seasonID:seasonID,seasonTitle:title),cid:item["cid"].int,title:item["show_title"].string.isEmpty ? item["title"].string+" "+item["long_title"].string:item["show_title"].string,page:index+1)}
        Task { await playback.open(video:target,cid:episode["cid"].int,library:library,episodes:list) }
        Task { await loadComments(episode) }
    }
    private func loadComments(_ episode:JSON) async {
        do { let data=try await BiliAPI.shared.comments(aid:episode["aid"].int);if selected["id"].int==episode["id"].int {comments=data["replies"].array} } catch { /* playback remains available */ }
    }
    private func follow() {
        guard account.loggedIn else {login=true;return};guard !busy else {return};busy=true
        Task { defer {busy=false};do { _=try await BiliAPI.shared.request(followed ? "/pgc/web/follow/del":"/pgc/web/follow/add",["season_id":"\(seasonID)"],post:true);followed.toggle() } catch {failure=error.localizedDescription} }
    }
    private func like(_ comment:JSON) {
        guard account.loggedIn else {login=true;return};guard !busy else {return};busy=true
        Task { defer {busy=false};do { _=try await BiliAPI.shared.request("/x/v2/reply/action",["oid":selected["aid"].string,"type":"1","rpid":comment["rpid"].string,"action":"1"],post:true) } catch {failure=error.localizedDescription} }
    }
}
