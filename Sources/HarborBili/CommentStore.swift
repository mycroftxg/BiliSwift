import SwiftUI
import HarborCore

/// 播放器右侧评论栏的数据源：分页加载 + 展开子回复。
@MainActor @Observable final class CommentStore {
    var comments:[JSON]=[]
    var loading=false
    var hasMore=true
    var aid=0
    private var page=0
    var replies:[Int:[JSON]]=[:]
    var loadingReplies:Set<Int>=[]

    func start(aid:Int,bvid:String="") async {
        var resolved=aid
        if resolved == 0,!bvid.isEmpty,let detail=try? await BiliAPI.shared.detail(bvid) { resolved=detail["aid"].int }
        guard resolved != 0 else { return }
        if self.aid == resolved, !comments.isEmpty { return }
        self.aid=resolved;comments=[];page=0;hasMore=true;replies=[:]
        await loadMore()
    }
    func loadMore() async {
        guard !loading,hasMore,aid != 0 else { return }
        loading=true
        defer { loading=false }
        let next=page+1
        guard let data=try? await BiliAPI.shared.comments(aid:aid,page:next) else { hasMore=false;return }
        let items=data["replies"].array
        withAnimation(.snappy(duration:0.25)) { if next==1 { comments=items } else { comments += items } }
        page=next
        hasMore = !items.isEmpty
    }
    func loadReplies(root:Int) async {
        guard aid != 0,replies[root]==nil,!loadingReplies.contains(root) else { return }
        loadingReplies.insert(root)
        defer { loadingReplies.remove(root) }
        guard let data=try? await BiliAPI.shared.replies(aid:aid,root:root) else { return }
        let items=data["replies"].array
        withAnimation(.snappy(duration:0.25)) { replies[root]=items }
    }
}
