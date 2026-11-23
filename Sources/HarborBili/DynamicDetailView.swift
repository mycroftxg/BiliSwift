import SwiftUI
import HarborCore

/// 单条动态的详情页：完整正文 + 图片/视频 + 评论区。
struct DynamicDetailView:View {
    let item:DynamicItem
    @State private var comments:[JSON]=[]
    @State private var loading=false
    @State private var hasMore=true
    @State private var cursor = Cursor.main(0)
    @State private var target: DynamicItem.CommentTarget?

    private enum Cursor: Equatable {
        case main(Int)
        case legacy(Int)
    }
    @State private var errorText:String?
    private var creator:Creator { Creator(mid:item.mid,name:item.author,avatar:item.avatar) }

    var body:some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:18) {
                HStack(spacing:12) {
                    NavigationLink(value:AppRoute.creator(creator)) {
                        HStack(spacing:12) {
                            CoverImage(source:item.avatar,width:128,showsPlaceholderIcon:false)
                                .frame(width:46,height:46).clipShape(.circle).clipped()
                            VStack(alignment:.leading,spacing:3) {
                                Text(item.author).font(.headline)
                                Text(item.time).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                }
                if !item.text.isEmpty {
                    Text(item.text).font(.system(size:16)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal:false,vertical:true)
                }
                media
                HStack(spacing:22) {
                    if item.likes>0 { Label("\(item.likes)",systemImage:"hand.thumbsup") }
                    if item.comments>0 { Label("\(item.comments)",systemImage:"bubble.right") }
                }.font(.system(size:13)).foregroundStyle(.secondary)

                Divider().opacity(0.3)
                Text("评论").font(.title3.bold())
                ForEach(Array(comments.enumerated()),id:\.offset) { _,comment in
                    HStack(alignment:.top,spacing:10) {
                        CoverImage(source:comment["member"]["avatar"].string,width:96,showsPlaceholderIcon:false)
                            .frame(width:32,height:32).clipShape(.circle).clipped()
                        VStack(alignment:.leading,spacing:5) {
                            Text(comment["member"]["uname"].string).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            CommentTextView(text: comment["content"]["message"].string, emotes: comment["content"].commentEmoteURLs)
                            HStack(spacing:12) {
                                if comment["like"].int>0 { Label("\(comment["like"].int)",systemImage:"hand.thumbsup") }
                                if comment["rcount"].int>0 { Label("\(comment["rcount"].int)",systemImage:"bubble.right") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                    }
                }
                if loading, comments.isEmpty { ProgressView().controlSize(.small).padding(.vertical,8) }
                if let errorText {
                    HStack {
                        Text(errorText).font(.callout).foregroundStyle(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                } else if !loading, comments.isEmpty {
                    Text("还没有评论").font(.callout).foregroundStyle(.secondary)
                } else if !comments.isEmpty, hasMore {
                    AutoLoadFooter(hasMore: hasMore, loading: loading) { await load() }
                }
            }
            .padding(28)
            .frame(maxWidth:860,alignment:.leading)
            .frame(maxWidth:.infinity)
        }
        .navigationTitle("动态")
        .task { await load() }
    }

    @ViewBuilder private var media:some View {
        if let video=item.video {
            NavigationLink(value:AppRoute.video(video)) {
                HStack(spacing:12) {
                    Thumbnail(source:video.cover).frame(width:200,height:112).clipShape(.rect(cornerRadius:10))
                    VStack(alignment:.leading,spacing:6) {
                        Text(video.title).font(.callout.weight(.medium)).lineLimit(2)
                        Text(video.durationLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                }.padding(10).background(.quaternary.opacity(0.25),in:.rect(cornerRadius:12))
            }.buttonStyle(.plain)
        } else if !item.images.isEmpty {
            let count=item.images.count
            let columns=count==1 ? [GridItem(.flexible())]:Array(repeating:GridItem(.flexible(),spacing:6),count:min(3,count))
            LazyVGrid(columns:columns,spacing:6) {
                ForEach(Array(item.images.prefix(9).enumerated()),id:\.offset) { _,source in
                    AspectImage(source:source)
                }
            }
        }
    }

    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        errorText = nil
        defer { loading = false }

        do {
            var resolved = target ?? item.commentTarget
            if resolved == nil {
                resolved = try await BiliAPI.shared.dynamicDetail(item.id)?.commentTarget
            }
            try Task.checkCancellation()
            guard let resolved else { throw BiliError.invalid("这条动态未提供评论入口。") }
            target = resolved

            let data: JSON
            let requestedCursor: Cursor
            switch cursor {
            case .main(let next):
                do {
                    data = try await BiliAPI.shared.dynamicComments(resolved, next: next)
                    requestedCursor = cursor
                } catch {
                    try Task.checkCancellation()
                    guard next == 0 else { throw error }
                    data = try await BiliAPI.shared.dynamicComments(resolved, page: 1)
                    requestedCursor = .legacy(1)
                }
            case .legacy(let page):
                data = try await BiliAPI.shared.dynamicComments(resolved, page: page)
                requestedCursor = cursor
            }
            try Task.checkCancellation()
            let replies = data["replies"].array
            var seen = Set(comments.map(commentID).filter { !$0.isEmpty })
            comments += replies.filter {
                let id = commentID($0)
                return id.isEmpty || seen.insert(id).inserted
            }
            switch requestedCursor {
            case .main(let next):
                let info = data["cursor"]
                let following = info["next"].int
                hasMore = !replies.isEmpty && !info["is_end"].bool && following > next
                cursor = .main(following)
            case .legacy(let page):
                let info = data["page"]
                hasMore = !replies.isEmpty && page * max(1, info["size"].int) < info["count"].int
                cursor = .legacy(page + 1)
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            errorText = "评论加载失败：\(error.localizedDescription)"
        }
    }

    private func commentID(_ comment: JSON) -> String {
        let id = comment["rpid_str"].string
        return id.isEmpty ? comment["rpid"].string : id
    }
}
