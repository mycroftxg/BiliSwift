import Foundation
import SwiftUI
import HarborCore

struct WatchRecord:Codable,Identifiable {
    var id:String { video.bvid }
    var video:Video, cid:Int, seconds:Double, updated:Date
}
@MainActor @Observable final class LocalLibrary {
    var records:[WatchRecord]=[]
    var notice:String?
    private let url:URL
    init() {
        let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("HarborBili",isDirectory:true)
        url=base.appendingPathComponent("history.json")
        do {
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
            if FileManager.default.fileExists(atPath:url.path) { records=try JSONDecoder().decode([WatchRecord].self,from:Data(contentsOf:url)) }
        } catch { notice="本地历史记录读取失败：\(error.localizedDescription)" }
    }
    func progress(_ bvid:String,cid:Int)->Double { records.first { $0.id==bvid && $0.cid==cid }?.seconds ?? 0 }
    func save(video:Video,cid:Int,seconds:Double) {
        guard seconds.isFinite,seconds>=0 else { return }
        records.removeAll { $0.id==video.bvid };records.insert(WatchRecord(video:video,cid:cid,seconds:seconds,updated:Date()),at:0)
        records=Array(records.prefix(300))
        persist()
    }
    func clear() { records=[];persist() }
    private func persist() {
        do { try JSONEncoder().encode(records).write(to:url,options:[.atomic,.completeFileProtection]) }
        catch { notice="本地历史记录保存失败：\(error.localizedDescription)" }
    }
}
enum Destination:String,CaseIterable,Identifiable {
    case website="Web 版",home="首页",search="搜索",dynamic="动态",channels="分区",messages="消息",following="我的关注",space="个人空间",history="观看历史",later="稍后再看",favorites="收藏夹",live="直播",shows="番剧与影视"
    var id:String { rawValue }
    var symbol:String {
        switch self { case .website:"globe";case .home:"house";case .search:"magnifyingglass";case .dynamic:"rectangle.stack";case .history:"clock";case .later:"text.badge.plus";case .favorites:"star";case .live:"dot.radiowaves.left.and.right";case .shows:"tv";case .channels:"square.grid.2x2";case .messages:"bubble.left.and.bubble.right";case .following:"person.2";case .space:"person.crop.rectangle" }
    }
    var requiresLogin:Bool { [.dynamic,.later,.favorites].contains(self) }
}
@MainActor @Observable final class Catalog {
    var videos:[Video]=[]
    var dynamics:[DynamicItem]=[]
    var loading=false
    var error:String?
    var page=1
    var canLoadMore=true
    var folders:[JSON]=[]
    var folderID=0
    var localHistory=false
    private var historyMax="0"
    private var historyAt="0"
    private var dynamicOffset=""
    private var feedFresh=0
    private var generation=UUID()
    func load(_ destination:Destination,keyword:String,account:AccountSession,library:LocalLibrary,more:Bool=false,channel:BiliChannel?=nil) async {
        let ticket:UUID
        if more { guard !loading,canLoadMore else { return }; ticket=generation }
        else { feedFresh &+= 1; ticket=UUID();generation=ticket;videos=[];dynamics=[];page=1;canLoadMore=true;historyMax="0";historyAt="0";dynamicOffset="" }
        loading=true;error=nil
        defer { if generation==ticket { loading=false } }
        do {
            if destination.requiresLogin && !account.loggedIn { throw BiliError.loginRequired }
            var result:[Video]=[]
            var reportedMore:Bool?
            if let channel {
                let response=try await BiliAPI.shared.channel(channel,page:page,fresh:feedFresh)
                result=response.videos;reportedMore=response.hasMore
            } else {
            switch destination {
            case .home:
                // 首页推荐一次取多页，保证「热门精选 / 继续发现 / 为你发现更多」三段都有内容。
                var seen=Set(videos.map(\.id))
                for index in (more ? [page]:[1,2,3]) {
                    let batch=try await BiliAPI.shared.homeFeed(page:index,fresh:feedFresh)
                    for video in batch where !video.bvid.isEmpty && !seen.contains(video.id) {
                        seen.insert(video.id);result.append(video)
                    }
                }
            case .search:
                if !keyword.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { result=try await BiliAPI.shared.search(keyword,page:page) }
            case .history:
                if !account.loggedIn || localHistory { result=library.records.map(\.video) }
                else {
                    let data=try await BiliAPI.shared.request("/x/web-interface/history/cursor",["max":historyMax,"view_at":historyAt,"business":"archive","ps":"20"])
                    guard generation==ticket else { return }
                    historyMax=data["cursor"]["max"].string;historyAt=data["cursor"]["view_at"].string
                    result=data["list"].array.compactMap { entry in
                        guard entry["history"]["business"].string=="archive" else { return nil }
                        return Video(.object(["bvid":entry["history"]["bvid"],"aid":entry["history"]["oid"],"title":entry["title"],"pic":entry["cover"],"author":entry["author_name"],"mid":entry["author_mid"],"duration":entry["duration"]]))
                    }
                }
            case .later:
                result=try await BiliAPI.shared.request("/x/v2/history/toview")["list"].array.map { Video($0) }
            case .favorites:
                if folders.isEmpty {
                    folders=try await BiliAPI.shared.request("/x/v3/fav/folder/created/list-all",["up_mid":"\(account.mid)"])["list"].array
                }
                if folderID==0 { folderID=folders.first?["id"].int ?? 0 }
                if folderID != 0 {
                    result=try await BiliAPI.shared.request("/x/v3/fav/resource/list",["media_id":"\(folderID)","pn":"\(page)","ps":"20","platform":"web"])["medias"].array.map { Video($0) }
                }
            case .dynamic:
                let data=try await BiliAPI.shared.dynamics(offset:dynamicOffset)
                guard generation==ticket else { return }
                dynamicOffset=data["offset"].string
                let items=data["items"].array.compactMap(DynamicItem.init)
                let known=Set(dynamics.map(\.id))
                dynamics += items.filter { !known.contains($0.id) }
                canLoadMore = !dynamicOffset.isEmpty && !items.isEmpty
                page += 1
                return
                result=data["items"].array.compactMap { item in
                    let archive=item["modules"]["module_dynamic"]["major"]["archive"]
                    guard !archive["bvid"].string.isEmpty else { return nil }
                    let author=item["modules"]["module_author"]
                    return Video(.object(["bvid":archive["bvid"],"aid":archive["aid"],"title":archive["title"],"pic":archive["cover"],"duration":archive["duration_text"],"author":author["name"],"mid":author["mid"]]))
                }
            case .live: result=try await BiliAPI.shared.liveRooms(page:page);reportedMore = !result.isEmpty
            case .website,.shows,.channels,.messages,.following,.space: break
            }
            }
            guard generation==ticket else { return }
            let existing=Set(videos.map(\.id));let fresh=result.filter { !existing.contains($0.id) && !$0.bvid.isEmpty };videos += fresh
            canLoadMore = ([.home,.search,.favorites].contains(destination) && result.count>=(destination == .home ? 12:20))
                || (destination == .history && account.loggedIn && !localHistory && result.count>=20)
                || (destination == .dynamic && !dynamicOffset.isEmpty && !result.isEmpty)
            if let reportedMore { canLoadMore=reportedMore }
            if more && fresh.isEmpty { canLoadMore=false }
            page += 1
        } catch { if generation==ticket { self.error=error.localizedDescription } }
    }
    func resetAccountData() { generation=UUID();videos=[];folders=[];folderID=0;loading=false }
}
