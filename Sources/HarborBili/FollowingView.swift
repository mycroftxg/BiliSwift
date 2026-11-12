import SwiftUI
import HarborCore

/// 原生「我的关注」：按页加载关注的 UP 主，点击进入原生空间。
struct FollowingView:View {
    @Environment(AccountSession.self) private var account
    @State private var people:[Creator]=[]
    @State private var page=1
    @State private var loading=false
    @State private var more=true
    @State private var error:String?
    @State private var login=false
    var body:some View {
        Group {
            if !account.loggedIn {
                ContentUnavailableView { Label("登录后查看关注",systemImage:"person.2") } description:{ Text("登录后可在这里浏览关注的全部 UP 主。").font(.callout) }
                    actions:{ Button("登录") { login=true }.buttonStyle(.glassProminent) }
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:20) {
                        Text("我的关注").font(.largeTitle.bold())
                        if let error { Text(error).font(.callout).foregroundStyle(.red) }
                        if loading && people.isEmpty { ProgressView().padding() }
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:230,maximum:320),spacing:18)],alignment:.leading,spacing:18) {
                            ForEach(people) { person in
                                NavigationLink(value:AppRoute.creator(person)) {
                                    HStack(spacing:12) {
                                        AvatarView(source:person.avatar,size:52)
                                        VStack(alignment:.leading,spacing:5) {
                                            Text(person.name).font(.headline).lineLimit(1)
                                            Text(person.signature.isEmpty ? "这个人很神秘，什么都没写":person.signature).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        Spacer(minLength:0)
                                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                                        .background(.quaternary.opacity(0.22),in:.rect(cornerRadius:14))
                                }.buttonStyle(.plain)
                            }
                        }
                        if more,!loading { Button("加载更多") { Task { await load() } }.buttonStyle(.glass).frame(maxWidth:.infinity) }
                        if !loading,people.isEmpty { ContentUnavailableView("还没有关注任何 UP 主",systemImage:"person.2.slash") }
                    }.padding(32)
                }
            }
        }
        .navigationTitle("我的关注")
        .task { await load() }
        .sheet(isPresented:$login) { LoginSheet().environment(account) }
    }
    private func load() async {
        guard account.loggedIn,!loading,more else { return }
        loading=true;defer { loading=false }
        do {
            let data=try await BiliAPI.shared.followings(account.mid,page:page)
            let list=data["list"].array.map(Creator.init)
            let ids=Set(people.map(\.id))
            people += list.filter { !ids.contains($0.id) }
            more=list.count>=30;page += 1
        } catch { self.error=error.localizedDescription;more=false }
    }
}
