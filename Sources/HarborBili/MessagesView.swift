import SwiftUI
import HarborCore

/// 原生消息中心：回复我的 / @我的 / 收到的赞；私信与系统通知保留官方网页入口。
struct MessagesView:View {
    @Environment(AccountSession.self) private var account
    @Environment(\.openURL) private var openURL
    @State private var tab="reply"
    @State private var items:[JSON]=[]
    @State private var loading=false
    @State private var error:String?
    @State private var login=false
    private let tabs=[("reply","回复我的"),("at","@我的"),("like","收到的赞")]
    var body:some View {
        Group {
            if !account.loggedIn {
                ContentUnavailableView { Label("登录后查看消息",systemImage:"bubble.left.and.bubble.right") } description:{ Text("消息中心读取你的回复、@ 与点赞通知。").font(.callout) }
                    actions:{ Button("登录") { login=true }.buttonStyle(.glassProminent) }
            } else {
                VStack(spacing:0) {
                    Picker("消息分类",selection:$tab) { ForEach(tabs,id:\.0) { Text($0.1).tag($0.0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth:360).padding(.vertical,14)
                    if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal,24) }
                    if loading && items.isEmpty { ProgressView().padding() }
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:0) {
                            ForEach(items.indices,id:\.self) { index in messageRow(items[index]) }
                            if items.isEmpty,!loading,!account.loggedIn==false { Text("暂时没有新消息").font(.callout).foregroundStyle(.secondary).padding(24) }
                        }.padding(.horizontal,24).padding(.bottom,24)
                    }
                }
            }
        }
        .navigationTitle("消息")
        .task(id:tab) { await load() }
        .sheet(isPresented:$login) { LoginSheet().environment(account) }
    }
    private func load() async {
        guard account.loggedIn else { items=[];return }
        loading=true;error=nil;items=[]
        defer { loading=false }
        do { items=try await BiliAPI.shared.msgFeed(tab)["items"].array }
        catch { self.error=error.localizedDescription }
    }
    private func messageRow(_ item:JSON)->some View {
        let user=item["user"], reply=item["reply"], source=item["item"]
        let bvid=bvid(from:source["uri"].string.isEmpty ? (reply["uri"].string.isEmpty ? source["source"].string:reply["uri"].string):source["uri"].string)
        return Group {
            if let bvid {
                NavigationLink(value:AppRoute.video(Video(.object([
                    "bvid":.string(bvid),"aid":.number(Double(source["source"].int != 0 ? source["source"].int : reply["oid"].int)),
                    "title":.string(source["title"].string.isEmpty ? reply["title"].string:source["title"].string),
                    "pic":.string(source["image_urls"].array.first?.string ?? ""),
                    "author":.string(user["nickname"].string),"mid":user["mid"]
                ])))) { rowContent(item,user:user,reply:reply,source:source) }.buttonStyle(.plain)
            } else { rowContent(item,user:user,reply:reply,source:source) }
        }
    }
    private func rowContent(_ item:JSON,user:JSON,reply:JSON,source:JSON)->some View {
        let message=reply["content"]["message"].string.isEmpty ? (source["title"].string.isEmpty ? "给你点了个赞":source["title"].string):reply["content"]["message"].string
        let context=source["title"].string
        return HStack(alignment:.top,spacing:12) {
            AvatarView(source:user["avatar"].string,size:42)
            VStack(alignment:.leading,spacing:6) {
                HStack(spacing:8) { Text(user["nickname"].string).font(.system(size:14,weight:.semibold)); Text(time(item["time"].int)).font(.caption).foregroundStyle(.secondary) }
                Text(message).font(.system(size:14)).lineSpacing(3).lineLimit(3).textSelection(.enabled)
                if !context.isEmpty,context != message { Text(context).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength:8)
            Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical,14).contentShape(.rect)
        .overlay(alignment:.bottom) { Divider().opacity(0.5) }
    }
    private func bvid(from text:String)->String? {
        guard let range=text.range(of:"BV[0-9A-Za-z]{10}",options:.regularExpression) else { return nil }
        return String(text[range])
    }
    private func time(_ stamp:Int)->String {
        guard stamp>0 else { return "" }
        let date=Date(timeIntervalSince1970:TimeInterval(stamp))
        let formatter=DateFormatter();formatter.dateFormat="MM-dd HH:mm";formatter.locale=Locale(identifier:"zh_CN")
        return formatter.string(from:date)
    }
}
