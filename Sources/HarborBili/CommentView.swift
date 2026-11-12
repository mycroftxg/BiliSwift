import SwiftUI
import HarborCore

struct CommentRow:View {
    let entry:JSON,aid:Int
    let onLike:(JSON)->Void
    let onLogin:()->Void
    @Environment(AccountSession.self) private var account
    @State private var fullText=false
    @State private var expanded=false
    @State private var replies:[JSON]=[]
    @State private var loading=false
    @State private var page=0
    @State private var hasMore=true
    @State private var failure:String?
    @State private var replying=false
    private var preview:[JSON] { Array(entry["replies"].array.prefix(3)) }
    private var replyCount:Int { max(entry["rcount"].int,entry["replies"].array.count) }
    var body:some View {
        HStack(alignment:.top,spacing:14) {
            AvatarView(source:entry["member"]["avatar"].string,size:42)
            VStack(alignment:.leading,spacing:10) {
                HStack(spacing:8) {
                    Text(entry["member"]["uname"].string).font(.system(size:13,weight:.semibold)).foregroundStyle(.secondary)
                    if entry["member"]["vip"]["vipStatus"].int==1 { Text("大会员").font(.system(size:9,weight:.medium)).foregroundStyle(.pink).padding(.horizontal,5).padding(.vertical,2).background(.pink.opacity(0.08),in:.capsule) }
                }
                Text(entry["content"]["message"].string).font(.system(size:14)).lineSpacing(5).lineLimit(fullText ? nil:8).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                if entry["content"]["message"].string.count>240 || entry["content"]["message"].string.filter({$0=="\n"}).count>6 {
                    Button(fullText ? "收起正文":"展开全文") { fullText.toggle() }.buttonStyle(.plain).font(.system(size:12,weight:.medium)).foregroundStyle(.tint)
                }
                HStack(spacing:18) {
                    if entry["ctime"].double>0 { Text(Date(timeIntervalSince1970:entry["ctime"].double),format:.dateTime.year().month().day()).font(.system(size:11)).foregroundStyle(.tertiary) }
                    Button { onLike(entry) } label:{ Label(entry["like"].int>0 ? entry["like"].int.formatted():"点赞",systemImage:"hand.thumbsup") }.font(.system(size:12)).foregroundStyle(.secondary)
                    Button("回复") { if account.loggedIn { replying=true } else { onLogin() } }.font(.system(size:12)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).padding(.top,2)
                if replyCount>0 {
                    VStack(alignment:.leading,spacing:14) {
                        ForEach((expanded ? replies:preview).indices,id:\.self) { index in
                            let reply=(expanded ? replies:preview)[index]
                            HStack(alignment:.top,spacing:9) {
                                AvatarView(source:reply["member"]["avatar"].string,size:25)
                                VStack(alignment:.leading,spacing:4) {
                                    Text(reply["member"]["uname"].string).font(.system(size:12,weight:.semibold)).foregroundStyle(.secondary)
                                    Text(reply["content"]["message"].string).font(.system(size:13)).lineSpacing(4).lineLimit(expanded ? nil:3).textSelection(.enabled)
                                }
                            }
                        }
                        if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
                        HStack(spacing:16) {
                            if expanded {
                                if hasMore { Button("加载更多回复") { Task { await loadReplies() } }.disabled(loading) }
                                Button("收起回复") { expanded=false }
                            } else { Button("展开 \(replyCount.formatted()) 条回复") { expanded=true;if replies.isEmpty { Task { await loadReplies() } } } }
                            if loading { ProgressView().controlSize(.mini) }
                        }.font(.system(size:12,weight:.medium)).buttonStyle(.plain).foregroundStyle(.tint)
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.35),in:.rect(cornerRadius:13))
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.vertical,24).overlay(alignment:.bottom) { Divider().padding(.leading,56) }
            .sheet(isPresented:$replying) { ReplyComposer(aid:aid,root:entry["rpid"].string,parent:entry["rpid"].string,name:entry["member"]["uname"].string).environment(account) }
    }
    private func loadReplies() async {
        guard !loading,hasMore else { return };loading=true;failure=nil;defer { loading=false }
        do {
            let data=try await BiliAPI.shared.request("/x/v2/reply/reply",["oid":"\(aid)","type":"1","root":entry["rpid"].string,"pn":"\(page+1)","ps":"20"])
            let next=data["replies"].array
            let existing=Set(replies.map { $0["rpid"].string })
            replies += next.filter { !existing.contains($0["rpid"].string) };page += 1
            hasMore = !next.isEmpty && replies.count<max(replyCount,data["page"]["count"].int)
        } catch { failure="回复加载失败：\(error.localizedDescription)" }
    }
}
struct ReplyComposer:View {
    let aid:Int,root:String,parent:String,name:String
    @Environment(\.dismiss) private var dismiss
    @State private var text=""
    @State private var busy=false
    @State private var confirm=false
    @State private var failure:String?
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("回复 \(name)").font(.title2.bold())
            TextField("写下回复…",text:$text,axis:.vertical).lineLimit(5...10).textFieldStyle(.roundedBorder).font(.body)
            if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
            HStack { Button("取消") { dismiss() };Spacer();Button("发布回复") { confirm=true }.buttonStyle(.glassProminent).disabled(busy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width:500)
            .alert("发布这条回复？",isPresented:$confirm) { Button("取消",role:.cancel) {};Button("发布") { Task { await submit() } } } message:{Text(text)}
    }
    private func submit() async {
        guard !busy else { return };busy=true;defer { busy=false }
        do { _=try await BiliAPI.shared.request("/x/v2/reply/add",["oid":"\(aid)","type":"1","root":root,"parent":parent,"message":text,"plat":"1"],post:true);dismiss() }
        catch { failure=error.localizedDescription+"；如结果不确定，请先刷新确认。" }
    }
}
