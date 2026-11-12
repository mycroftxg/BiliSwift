import SwiftUI
import HarborCore

@MainActor @Observable final class SearchModel {
    var query=""
    var submitted=""
    var scope=SearchScope.all
    var order="totalrank"
    var videos:[Video]=[]
    var licensedVideos:[Video]=[]
    var users:[Creator]=[]
    var articles:[JSON]=[]
    var loading=false
    var failure:String?
    var userFailure:String?
    var page=1
    var hasMore=false
    private var generation=UUID()
    func load(more:Bool=false) async {
        if more && (loading || !hasMore) {return}
        if !more {generation=UUID();videos=[];licensedVideos=[];users=[];articles=[];page=1;failure=nil;userFailure=nil}
        let ticket=generation
        guard !submitted.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {return}
        loading=true;defer {if ticket==generation {loading=false}}
        do {
            async let result=BiliAPI.shared.searchResults(submitted,scope:scope,page:page,order:order)
            if scope == .all,!more {
                async let bangumi = licensedResults(submitted, scope: .bangumi)
                async let films = licensedResults(submitted, scope: .film)
                let official = await bangumi + films
                guard ticket == generation else { return }
                var seen = Set<String>()
                licensedVideos = official.filter { seen.insert($0.id).inserted }.sorted {
                    ($0.title == submitted ? 0 : 1) < ($1.title == submitted ? 0 : 1)
                }
                do {let matches=try await BiliAPI.shared.searchResults(submitted,scope:.user);if ticket==generation {users=Array(matches["result"].array.prefix(20).map(Creator.init))}}
                catch {if ticket==generation {userFailure="UP 主推荐暂不可用"}}
            }
            let data=try await result
            guard ticket==generation else {return}
            let rows=data["result"].array
            switch scope {
            case .all,.video: videos += rows.map {Video($0)}.filter {!$0.bvid.isEmpty}
            case .bangumi,.film: videos += rows.map {Video(season:$0)}.filter { ($0.seasonID ?? 0) > 0 }
            case .live: videos += data["result"]["live_room"].array.map {Video(room:$0)}
            case .user:users += rows.map(Creator.init)
            case .article:articles += rows
            }
            hasMore = page<max(data["numPages"].int,Int(ceil(data["numResults"].double/20)))
            page += 1
        } catch {if ticket==generation {failure=error.localizedDescription}}
    }
    private func licensedResults(_ query: String, scope: SearchScope) async -> [Video] {
        guard let result = try? await BiliAPI.shared.searchResults(query, scope: scope) else { return [] }
        return result["result"].array.map { Video(season: $0) }.filter { ($0.seasonID ?? 0) > 0 }
    }

    func submit() async {submitted=query.trimmingCharacters(in:.whitespacesAndNewlines);await load()}
}
struct NativeSearchView:View {
    let onVideo:(Video)->Void,onCreator:(Creator)->Void
    @Environment(WindowPresentation.self) private var presentation
    @Environment(AppPreferences.self) private var preferences
    @State private var model=SearchModel()
    @FocusState private var searchFocused: Bool
    @State private var suggestions: [String] = []
    @State private var suggestedTerm = ""
    @State private var fieldWidth:CGFloat = 600
    private var term: String { model.query.trimmingCharacters(in: .whitespacesAndNewlines) }
    @State private var nearBottom=false
    private var key:String {model.scope.rawValue+model.order}
    private var showSuggestions:Bool { searchFocused && suggestedTerm == term && !suggestions.isEmpty }
    private var notableUsers:[Creator] { model.users.filter { $0.fans >= 100_000 } }
    var body:some View {
        @Bindable var m=model
        VStack(spacing:0) {
            VStack(spacing:18) {
                HStack(spacing:12) {
                    HStack(spacing:10) {Image(systemName:"magnifyingglass").foregroundStyle(.secondary);TextField("搜索视频、UP 主或 BV 号",text:$m.query).textFieldStyle(.plain).font(.system(size:17)).focused($searchFocused).onSubmit {submit()};if !model.query.isEmpty {Button {model.query=""} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary)} }
                        .padding(.horizontal,16).padding(.vertical,12).glassEffect(.regular,in:.rect(cornerRadius:14))
                        .onGeometryChange(for:CGFloat.self) { $0.size.width } action:{ fieldWidth=$0 }
                    Button("搜索") {submit()}.buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.return,modifiers:[])
                }
                .frame(maxWidth:760)
                .overlay(alignment:.topLeading) {
                    if showSuggestions {
                        VStack(alignment:.leading,spacing:2) {
                            ForEach(suggestions,id:\.self) { suggestion in
                                Button {
                                    model.query=suggestion
                                    submit()
                                } label:{
                                    Label(suggestion,systemImage:"magnifyingglass")
                                        .frame(maxWidth:.infinity,alignment:.leading)
                                        .padding(.horizontal,14).padding(.vertical,8)
                                        .contentShape(.rect)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                        .glassEffect(.regular,in:.rect(cornerRadius:16))
                        .shadow(color:.black.opacity(0.25),radius:18,y:10)
                        .frame(width:max(260,fieldWidth),alignment:.leading)
                        .offset(y:64)
                        .transition(.opacity)
                        .zIndex(20)
                    }
                }
                .frame(maxWidth:.infinity)
                .zIndex(20)
                .animation(.easeInOut(duration:0.18),value:showSuggestions)
                Picker("搜索分类",selection:$m.scope) {ForEach(SearchScope.allCases) {scope in Text(scope.rawValue).tag(scope)}}.pickerStyle(.segmented).labelsHidden().frame(maxWidth:880)
                if [.all,.video].contains(model.scope),!model.submitted.isEmpty {
                    HStack {Picker("排序",selection:$m.order) {Text("综合排序").tag("totalrank");Text("最多播放").tag("click");Text("最新发布").tag("pubdate");Text("最多弹幕").tag("dm");Text("最多收藏").tag("stow")}.pickerStyle(.menu).fixedSize();Spacer();Text("“\(model.submitted)”的搜索结果").font(.caption).foregroundStyle(.secondary)}
                }
            }.padding(.horizontal,32).padding(.vertical,22).frame(maxWidth:.infinity).background(.bar)
            if model.submitted.isEmpty {
                ContentUnavailableView("搜索你想看的内容",systemImage:"magnifyingglass",description:Text("发现视频、UP 主、番剧、影视和直播。")).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:28) {
                        if let failure=model.failure {ContentUnavailableView {Label("搜索未完成",systemImage:"wifi.exclamationmark")} description:{Text(failure)} actions:{Button("重试") {Task {await model.load()}}}.frame(maxWidth:.infinity)}
                        if model.scope == .all, !model.licensedVideos.isEmpty {
                            Text("影视作品").font(.title2.bold())
                            videoGrid(model.licensedVideos)
                        }
                        if model.scope == .all,!notableUsers.isEmpty {
                            Text("相关 UP 主").font(.title2.bold())
                            ForEach(Array(notableUsers.prefix(3))) { user in CreatorSearchCard(creator:user,onOpen:{onCreator(user)},onVideo:onVideo) }
                        }
                        if let warning=model.userFailure {Text(warning).font(.caption).foregroundStyle(.secondary)}
                        if model.scope == .user {
                            ForEach(model.users,id:\.mid) { user in
                                if user.fans >= 100_000 {
                                    CreatorSearchCard(creator:user,onOpen:{onCreator(user)},onVideo:onVideo)
                                } else {
                                    CreatorCompactRow(creator:user,onOpen:{onCreator(user)})
                                }
                            }
                        } else if model.scope == .article {
                            ForEach(model.articles.indices,id:\.self) {index in ArticleResultRow(article:model.articles[index])}
                        } else if !model.videos.isEmpty {
                            if model.scope == .all {Text("视频").font(.title2.bold())}
                            videoGrid(model.videos)
                        }
                        if model.loading {ProgressView("正在搜索…").frame(maxWidth:.infinity)}
                        if !model.loading,model.failure==nil,model.videos.isEmpty,model.licensedVideos.isEmpty,model.users.isEmpty,model.articles.isEmpty {ContentUnavailableView("没有找到结果",systemImage:"magnifyingglass",description:Text("尝试更换关键词或搜索分类。")).frame(maxWidth:.infinity)}
                        if model.hasMore {Button("更多结果") {Task {await model.load(more:true)}}.buttonStyle(.glass).frame(maxWidth:.infinity).disabled(model.loading)}
                    }.padding(32)
                }.onScrollGeometryChange(for:Bool.self) {$0.contentOffset.y+$0.containerSize.height>$0.contentSize.height-400} action:{_,value in nearBottom=value;if value,model.hasMore,!model.loading {Task {await model.load(more:true)}}}
            }
        }.onAppear {presentation.toolbarOverCover=false}
            .task(id:key) {if !model.submitted.isEmpty {await model.load()}}
            .task(id: term) {
                let query = term
                if !suggestions.isEmpty { withAnimation(.easeInOut(duration:0.16)) { suggestions=[] } }
                guard !query.isEmpty else { return }
                do {
                    try await Task.sleep(for: .milliseconds(220))
                    let values = try await BiliAPI.shared.searchSuggestions(query)
                    guard !Task.isCancelled, query == term else { return }
                    withAnimation(.easeInOut(duration:0.18)) {
                        suggestedTerm = query
                        suggestions = Array(values.prefix(6))
                    }
                } catch { }
            }
    }

    private func submit() {
        searchFocused = false
        Task { await model.submit() }
    }

    private func videoGrid(_ videos: [Video]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 20)],
                  alignment: .leading, spacing: 26) {
            ForEach(videos) { video in
                Button { onVideo(video) } label: {
                    VideoCard(video: video, seasonBackdropToken: video.isSeason ? preferences.values.tmdbToken : nil)
                }.buttonStyle(.plain)
            }
        }
    }

}
struct CreatorSearchCard:View {
    let creator:Creator,onOpen:()->Void,onVideo:(Video)->Void
    @Environment(AccountSession.self) private var account
    @State private var following=false
    @State private var busy=false
    @State private var message:String?
    @State private var login=false
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:14) {
                Button(action:onOpen) {AvatarView(source:creator.avatar,size:58)}.buttonStyle(.plain)
                VStack(alignment:.leading,spacing:5) {
                    Button(creator.name,action:onOpen).buttonStyle(.plain).font(.system(size:17,weight:.semibold))
                    Text("\(creator.fans.formatted()) 粉丝 · \(creator.videoCount.formatted()) 个视频").font(.caption).foregroundStyle(.secondary)
                    if !creator.signature.isEmpty {Text(creator.signature).font(.system(size:12)).foregroundStyle(.secondary).lineLimit(2)}
                }
                Spacer()
                Button(following ? "已关注":"关注") {follow()}.buttonStyle(.glass).disabled(busy)
                Button("查看主页",action:onOpen).buttonStyle(.glass)
            }
            if let message {Text(message).font(.caption).foregroundStyle(.secondary)}
            if !creator.recent.isEmpty {
                ScrollView(.horizontal) {LazyHStack(alignment:.top,spacing:18) {ForEach(creator.recent) {video in Button {onVideo(video)} label:{VideoCard(video:video).frame(width:240)}.buttonStyle(.plain)}}}.scrollIndicators(.hidden).shelfBleed(32)
            }
        }.padding(20).background(.quaternary.opacity(0.2),in:.rect(cornerRadius:18)).sheet(isPresented:$login) {LoginSheet().environment(account)}
    }
    private func follow() {
        guard account.loggedIn else {login=true;return};guard !busy else {return};busy=true
        Task {defer{busy=false};do {_=try await BiliAPI.shared.request("/x/relation/modify",["fid":"\(creator.mid)","act":following ? "2":"1","re_src":"11"],post:true);following.toggle()}catch{message=error.localizedDescription}}
    }
}
struct ArticleResultRow:View {
    let article:JSON
    @Environment(\.openURL) private var openURL
    var body:some View {
        Button {openURL(URL(string:"https://www.bilibili.com/read/cv\(article["id"].int)")!)} label:{
            HStack(alignment:.top,spacing:18) {
                if let first=article["image_urls"].array.first {Thumbnail(source:Video.secure(first.string)).frame(width:180).clipShape(.rect(cornerRadius:10))}
                VStack(alignment:.leading,spacing:9) {Text(Creator.plain(article["title"].string)).font(.headline).lineLimit(2);Text(Creator.plain(article["desc"].string)).font(.callout).foregroundStyle(.secondary).lineLimit(3);Text(article["author"].string.isEmpty ? article["author"]["name"].string:article["author"].string).font(.caption).foregroundStyle(.tertiary)}
                Spacer()
            }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12)
        }.buttonStyle(.plain)
    }
}

/// 粉丝不足 10 万的 UP：不单独给卡片框，只保留一行紧凑结果。
struct CreatorCompactRow:View {
    let creator:Creator
    var onOpen:()->Void
    var body:some View {
        HStack(spacing:12) {
            Button(action:onOpen) { AvatarView(source:creator.avatar,size:34) }.buttonStyle(.plain)
            VStack(alignment:.leading,spacing:2) {
                Button(creator.name,action:onOpen).buttonStyle(.plain).font(.system(size:14,weight:.medium))
                Text("\(creator.fans.formatted()) 粉丝").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("查看主页",action:onOpen).buttonStyle(.glass).controlSize(.small)
        }
        .padding(.vertical,6)
    }
}
