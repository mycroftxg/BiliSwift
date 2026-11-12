import SwiftUI
import HarborCore

@MainActor @Observable final class DetailModel {
    var detail:JSON = .null
    var comments:[JSON]=[]
    var related:[Video]=[]
    var loading=false
    var busy=false
    var error:String?
    var notice:String?
    var liked=false
    var commentPage=1
    var hasMoreComments=true
    var pages:[Episode] { detail["pages"].array.map(Episode.init) }
    var collectionTitle:String { detail["ugc_season"]["title"].string }
    var collectionEpisodes:[CollectionEpisode] {
        detail["ugc_season"]["sections"].array.flatMap { $0["episodes"].array }.enumerated().compactMap { CollectionEpisode($0.element,index:$0.offset) }
    }
    func load(_ video:Video) async {
        loading=true;defer { loading=false }
        do { detail=try await BiliAPI.shared.detail(video.bvid) } catch { self.error=error.localizedDescription;return }
        loading=false
        let aid=detail["aid"].int != 0 ? detail["aid"].int:video.aid
        async let commentRequest=BiliAPI.shared.comments(aid:aid)
        async let relatedRequest=BiliAPI.shared.related(video.bvid)
        do { comments=try await commentRequest["replies"].array } catch { notice="评论暂不可用：\(error.localizedDescription)" }
        do { related=try await relatedRequest } catch { /* detail remains usable */ }
        do { liked=try await BiliAPI.shared.request("/x/web-interface/archive/has/like",["bvid":video.bvid]).int==1 } catch { /* guest */ }
    }
    func moreComments(_ video:Video) async {
        guard !busy,hasMoreComments else { return };busy=true;defer { busy=false }
        let aid=detail["aid"].int != 0 ? detail["aid"].int:video.aid
        do { let next=commentPage+1;let data=try await BiliAPI.shared.comments(aid:aid,page:next)["replies"].array
            comments += data;commentPage=next;hasMoreComments = !data.isEmpty
        } catch { self.error=error.localizedDescription }
    }
    func perform(_ path:String,_ params:[String:String],success:String) async -> Bool {
        guard !busy else { return false };busy=true;defer { busy=false }
        do { _=try await BiliAPI.shared.request(path,params,post:true);notice=success;return true }
        catch { self.error="\(error.localizedDescription) 如操作结果不确定，请先刷新确认，避免重复提交。";return false }
    }
}
struct FavoriteSheet:View {
    let video:Video
    @Environment(\.dismiss) private var dismiss
    @State private var folders:[JSON]=[]
    @State private var selected:Set<Int>=[]
    @State private var original:Set<Int>=[]
    @State private var busy=false
    @State private var error:String?
    @Environment(AccountSession.self) private var account
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("收藏到…").font(.title2.bold())
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            List(folders.indices,id:\.self) { index in
                let folder=folders[index],id=folder["id"].int
                Toggle(folder["title"].string,isOn:Binding(get:{selected.contains(id)},set:{ if $0 { selected.insert(id) } else { selected.remove(id) } }))
            }.frame(minHeight:180)
            HStack { Button("取消") { dismiss() };Spacer();Button("保存") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(busy || folders.isEmpty) }
        }.padding(24).frame(width:420).task {
            busy=true;defer { busy=false }
            do {
                folders=try await BiliAPI.shared.request("/x/v3/fav/folder/created/list-all",["up_mid":"\(account.mid)","rid":"\(video.aid)","type":"2"])["list"].array
                selected=Set(folders.filter { $0["fav_state"].int==1 }.map { $0["id"].int });original=selected
                if folders.isEmpty { error="账号尚无收藏夹，请先在官方网页创建。" }
            } catch { self.error=error.localizedDescription }
        }
    }
    private func save() async {
        busy=true;defer { busy=false }
        let added=selected.subtracting(original),removed=original.subtracting(selected)
        if added.isEmpty && removed.isEmpty { dismiss();return }
        do {
            _=try await BiliAPI.shared.request("/x/v3/fav/resource/deal",["rid":"\(video.aid)","type":"2","add_media_ids":added.sorted().map(String.init).joined(separator:","),"del_media_ids":removed.sorted().map(String.init).joined(separator:",")],post:true)
            dismiss()
        } catch { self.error=error.localizedDescription }
    }
}
