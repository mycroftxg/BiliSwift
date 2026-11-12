import SwiftUI
import HarborCore

/// 单条动态的详情页：完整正文 + 图片/视频 + 评论区。
struct DynamicDetailView:View {
    let item:DynamicItem
    @State private var comments:[JSON]=[]
    @State private var loading=false
    @State private var hasMore=true
    @State private var page=0
    @State private var next=0
    @State private var errorText:String?
    private var creator:Creator { Creator(mid:item.mid,name:item.author,avatar:item.avatar) }

    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
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
                            Text(comment["content"]["message"].string).font(.callout).fixedSize(horizontal:false,vertical:true)
                            HStack(spacing:12) {
                                if comment["like"].int>0 { Label("\(comment["like"].int)",systemImage:"hand.thumbsup") }
                                if comment["rcount"].int>0 { Label("\(comment["rcount"].int)",systemImage:"bubble.right") }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                    }
                }
                if loading { ProgressView().controlSize(.small).padding(.vertical,8) }
                if hasMore,!comments.isEmpty { Button("加载更多评论") { Task { await load(more:true) } }.buttonStyle(.bordered).disabled(loading) }
                if comments.isEmpty,!loading { Text(errorText ?? "还没有评论").font(.callout).foregroundStyle(.secondary) }
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

    private func load(more:Bool=false) async {
        guard !loading,hasMore else { return }
        guard let oid=Int(item.id) else { return }
        loading=true
        defer { loading=false }
        let current=page+1
        var items:[JSON]=[]
        var done=false
        if let data=try? await BiliAPI.shared.comments(oid:oid,type:17,page:current),!data["replies"].array.isEmpty {
            items=data["replies"].array
            done=items.isEmpty
        } else if let data=try? await BiliAPI.shared.dynamicComments(oid:oid,next:next) {
            items=data["replies"].array
            next=data["cursor"]["next"].int
            done=data["cursor"]["is_end"].bool
        } else {
            errorText="评论接口暂时不可用"
        }
        if current==1 { comments=items } else { comments += items }
        page=current
        hasMore = done ? false:!items.isEmpty
    }
}
