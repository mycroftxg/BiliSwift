import SwiftUI
import HarborCore

/// 动态流：图文、视频、纯文字都完整展示。
struct DynamicFeedView:View {
    let items:[DynamicItem]
    let loading:Bool
    let canLoadMore:Bool
    let error:String?
    let onMore:()->Void

    private enum Filter:String,CaseIterable { case all="全部动态",video="视频投稿",image="图文" }
    @State private var filter:Filter = .all
    @State private var authorFilter:Int?
    @State private var liveRooms:[Video]=[]
    @State private var preview:String?

    private var authors:[(mid:Int,name:String,avatar:String)] {
        var seen=Set<Int>();var list:[(Int,String,String)]=[]
        for item in items where !seen.contains(item.mid) {
            seen.insert(item.mid);list.append((item.mid,item.author,item.avatar))
        }
        return Array(list.prefix(14))
    }
    private var filtered:[DynamicItem] {
        items.filter { item in
            if let authorFilter,item.mid != authorFilter { return false }
            switch filter {
            case .all: return true
            case .video: return item.video != nil
            case .image: return !item.images.isEmpty
            }
        }
    }

    var body:some View {
        ScrollView {
            LazyVStack(spacing:16) {
                filterBar
                if !liveRooms.isEmpty { liveStrip }
                ForEach(filtered) { item in
                    DynamicCard(item:item,onPreview:{ preview=$0 })
                        .onAppear { if item.id==filtered.last?.id,canLoadMore,!loading { onMore() } }
                }
                if loading { ProgressView().controlSize(.small).padding(.vertical,12) }
                if !canLoadMore,!filtered.isEmpty { Text("没有更多动态了").font(.caption).foregroundStyle(.secondary).padding(.vertical,10) }
                if filtered.isEmpty,!loading {
                    ContentUnavailableView { Label("还没有动态",systemImage:"rectangle.stack") } description:{ Text(error ?? "关注一些 UP 主，或者稍后刷新看看。") }
                }
            }
            .frame(maxWidth:940,alignment:.leading)
            .frame(maxWidth:.infinity)
            .padding(24)
        }
        .overlay { if let preview { ImageLightbox(source:preview,onClose:{ self.preview=nil }) } }
        .task {
            if liveRooms.isEmpty,let rooms=try? await BiliAPI.shared.liveRooms(page:1) { liveRooms=Array(rooms.prefix(8)) }
        }
    }

    private var filterBar:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:8) {
                ForEach(Filter.allCases,id:\.self) { item in
                    Button { withAnimation(.snappy(duration:0.2)) { filter=item } } label:{
                        Text(item.rawValue).font(.subheadline.weight(filter==item ? .semibold:.regular))
                            .padding(.horizontal,14).padding(.vertical,7)
                            .background(filter==item ? Color.primary.opacity(0.12):.clear,in:.capsule)
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            if authors.count>1 {
                ScrollView(.horizontal) {
                    HStack(spacing:14) {
                        Button { withAnimation(.snappy) { authorFilter=nil } } label:{ VStack(spacing:5) { Image(systemName:"square.grid.2x2.fill").font(.system(size:15)).frame(width:38,height:38).background(.quaternary,in:.circle);Text("全部").font(.caption2) } }.buttonStyle(.plain)
                        ForEach(authors,id:\.mid) { author in
                            Button { withAnimation(.snappy) { authorFilter = authorFilter==author.mid ? nil:author.mid } } label:{
                                VStack(spacing:5) {
                                    CoverImage(source:author.avatar,width:96,showsPlaceholderIcon:false)
                                        .frame(width:38,height:38).clipShape(.circle).clipped()
                                        .overlay { Circle().strokeBorder(authorFilter==author.mid ? Color.accentColor:.clear,lineWidth:2) }
                                    Text(author.name).font(.caption2).lineLimit(1).frame(width:52)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal,24,for:.scrollContent)
            }
        }
        .padding(.bottom,4)
    }

    private var liveStrip:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("正在直播").font(.title3.bold());Spacer() }
            ScrollView(.horizontal) {
                HStack(spacing:12) {
                    ForEach(liveRooms) { room in
                        NavigationLink(value:AppRoute.video(room)) {
                            VStack(alignment:.leading,spacing:6) {
                                Thumbnail(source:room.cover).frame(width:200,height:112).clipShape(.rect(cornerRadius:10))
                                Text(room.title).font(.caption.weight(.medium)).lineLimit(1).frame(width:200,alignment:.leading)
                                Text(room.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width:200,alignment:.leading)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal,24,for:.scrollContent)
        }
    }
}

struct DynamicCard:View {
    let item:DynamicItem
    var onPreview:(String)->Void
    private var creator:Creator { Creator(mid:item.mid,name:item.author,avatar:item.avatar) }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                NavigationLink(value:AppRoute.creator(creator)) {
                    HStack(spacing:10) {
                        CoverImage(source:item.avatar,width:96,showsPlaceholderIcon:false)
                            .frame(width:36,height:36).clipShape(.circle).clipped()
                        VStack(alignment:.leading,spacing:2) {
                            Text(item.author).font(.system(size:15,weight:.semibold))
                            Text(item.time).font(.system(size:12)).foregroundStyle(.secondary)
                        }
                    }.contentShape(.rect)
                }.buttonStyle(.plain)
                Spacer()
            }
            if !item.text.isEmpty {
                Text(item.text).font(.system(size:15)).lineSpacing(4)
                    .fixedSize(horizontal:false,vertical:true)
                    .textSelection(.enabled)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }
            media
            HStack(spacing:22) {
                if item.likes>0 { Label("\(item.likes)",systemImage:"hand.thumbsup") }
                NavigationLink(value:AppRoute.dynamic(item)) {
                    Label(item.comments>0 ? "\(item.comments)":"评论",systemImage:"bubble.right")
                }.buttonStyle(.plain)
                Spacer()
                NavigationLink(value:AppRoute.dynamic(item)) {
                    HStack(spacing:4) { Text("查看评论");Image(systemName:"chevron.right") }.font(.system(size:12,weight:.medium))
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }.font(.system(size:12)).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.quaternary.opacity(0.3),in:.rect(cornerRadius:18))
    }
    @ViewBuilder private var media:some View {
        if let video=item.video {
            NavigationLink(value:AppRoute.video(video)) {
                HStack(spacing:12) {
                    Thumbnail(source:video.cover).frame(width:180,height:101).clipShape(.rect(cornerRadius:10))
                    VStack(alignment:.leading,spacing:6) {
                        Text(video.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(video.durationLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:0)
                }
                .padding(10)
                .background(.quaternary.opacity(0.2),in:.rect(cornerRadius:12))
                .contentShape(.rect)
            }.buttonStyle(.plain)
        } else if !item.images.isEmpty {
            let count=item.images.count
            let columns=count==1 ? [GridItem(.flexible())]:Array(repeating:GridItem(.flexible(),spacing:6),count:min(3,count))
            LazyVGrid(columns:columns,spacing:6) {
                ForEach(Array(item.images.prefix(9).enumerated()),id:\.offset) { _,source in
                    Button { onPreview(source) } label:{
                        if count==1 {
                            HStack { AspectImage(source:source).frame(maxWidth:560); Spacer(minLength:0) }
                        } else {
                            AspectImage(source:source)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// 按图片原始宽高比撑开的图片视图。
struct AspectImage:View {
    let source:String
    @State private var ratio:CGFloat=16.0/9.0
    var body:some View {
        Color.clear
            .aspectRatio(ratio,contentMode:.fit)
            .overlay { RemoteImage(source:source,width:1080,showsPlaceholderIcon:false,fit:true) }
            .clipShape(.rect(cornerRadius:10))
            .task(id:source) {
                if let size=await RemoteImageStore.shared.pixelSize(source),size.height>0 { ratio=size.width/size.height }
            }
    }
}

/// 点击图片后的全屏查看。
struct ImageLightbox:View {
    let source:String
    var onClose:()->Void
    var body:some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea().onTapGesture { onClose() }
            RemoteImage(source:source,width:1920,showsPlaceholderIcon:false,fit:true)
                .padding(40)
                .allowsHitTesting(false)
            VStack { HStack { Spacer(); Button { onClose() } label:{ Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:34,height:34) }.buttonStyle(.glass).buttonBorderShape(.circle) }; Spacer() }.padding(20)
        }
        .transition(.opacity)
    }
}
