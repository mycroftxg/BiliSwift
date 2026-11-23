import SwiftUI
import HarborCore

/// 播放器右侧评论栏的数据源：分页加载 + 展开子回复。
@MainActor @Observable final class CommentStore {
    var comments: [JSON] = []
    var loading = false
    var hasMore = true
    var aid = 0
    var error: String?
    private enum Cursor {
        case sorted(String)
        case legacy(Int)
    }
    private var cursor = Cursor.sorted("")
    private var order = BiliAPI.CommentOrder.hot
    private var generation = UUID()
    var replies: [Int: [JSON]] = [:]
    var loadingReplies: Set<Int> = []

    func start(aid: Int, bvid: String, order: BiliAPI.CommentOrder) async {
        generation = UUID()
        let ticket = generation
        self.aid = aid
        self.order = order
        cursor = .sorted("")
        hasMore = true
        comments = []
        replies = [:]
        loadingReplies = []
        error = nil
        loading = true
        do {
            if aid == 0 {
                let detail = try await BiliAPI.shared.detail(bvid)
                guard generation == ticket, !Task.isCancelled else { return }
                self.aid = detail["aid"].int
            }
            guard self.aid > 0 else { throw BiliError.invalid("无法获取评论区。") }
        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
        if error == nil { await loadMore() }
    }

    func loadMore() async {
        guard !loading, hasMore, aid > 0 else { return }
        let ticket = generation
        error = nil
        loading = true
        defer { if generation == ticket { loading = false } }
        do {
            let data: JSON
            let requested: Cursor
            switch cursor {
            case .sorted(let offset):
                do {
                    data = try await BiliAPI.shared.sortedComments(oid: String(aid), order: order, offset: offset)
                    requested = .sorted(offset)
                } catch {
                    try Task.checkCancellation()
                    guard generation == ticket, offset.isEmpty, order == .hot else { throw error }
                    data = try await BiliAPI.shared.comments(aid: aid)
                    requested = .legacy(1)
                }
            case .legacy(let page):
                data = try await BiliAPI.shared.comments(aid: aid, page: page)
                requested = .legacy(page)
            }
            guard generation == ticket, !Task.isCancelled else { return }
            let items = data["replies"].array
            var seen = Set(comments.map(\.commentIdentity))
            comments += items.filter { seen.insert($0.commentIdentity).inserted }
            switch requested {
            case .sorted(let offset):
                let info = data["cursor"]
                let next = info["pagination_reply"]["next_offset"].string
                hasMore = !items.isEmpty && !info["is_end"].bool && !next.isEmpty && next != offset
                cursor = .sorted(next)
            case .legacy(let page):
                let info = data["page"]
                let total = info["count"].int
                let size = info["size"].int
                hasMore = !items.isEmpty && (total == 0 || size == 0 || page * size < total)
                cursor = .legacy(page + 1)
            }

        } catch {
            guard generation == ticket, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
    func loadReplies(root:Int, refresh: Bool = false) async {
        guard aid != 0,refresh || replies[root]==nil,!loadingReplies.contains(root) else { return }
        loadingReplies.insert(root)
        let ticket = generation
        defer { if generation == ticket { loadingReplies.remove(root) } }
        guard let data=try? await BiliAPI.shared.replies(aid:aid,root:root) else { return }
        guard generation == ticket, !Task.isCancelled else { return }
        let items=data["replies"].array
        withAnimation(.snappy(duration:0.25)) { replies[root]=items }
    }
}
