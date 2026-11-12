import SwiftUI
import WebKit
import Security
import HarborCore

struct SavedCookie: Codable {
    let name: String, value: String, domain: String, path: String
    let expires: Date?, secure: Bool
    init(_ c:HTTPCookie) { name=c.name; value=c.value; domain=c.domain; path=c.path; expires=c.expiresDate; secure=c.isSecure }
    var cookie: HTTPCookie? {
        var p:[HTTPCookiePropertyKey:Any] = [.name:name,.value:value,.domain:domain,.path:path,.secure:secure ? "TRUE":"FALSE"]
        if let expires { p[.expires] = expires }
        return HTTPCookie(properties:p)
    }
}
enum CredentialVault {
    static let service = "app.biliswift.mac.session"
    static var query:[String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:"bilibili"] }
    static func save(_ data:Data) throws {
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes=query; attributes[kSecValueData as String]=data
            attributes[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary,nil) == errSecSuccess else { throw BiliError.invalid("无法保存登录凭据到钥匙串") }; return
        }
        guard status == errSecSuccess else { throw BiliError.invalid("无法更新钥匙串凭据") }
    }
    static func read() -> Data? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?; guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess else { return nil }; return result as? Data
    }
    static func delete() throws { let status=SecItemDelete(query as CFDictionary); guard status==errSecSuccess || status==errSecItemNotFound else { throw BiliError.invalid("无法删除钥匙串凭据") } }
}
@MainActor @Observable final class AccountSession {
    var name = "未登录"
    var avatar=""
    var mid = 0
    var vip = false
    var busy = false
    var message:String?
    private var restored=false
    private var generation=UUID()
    var loggedIn:Bool { mid > 0 }
    static func trusted(_ c:HTTPCookie) -> Bool {
        let d = c.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")).lowercased()
        return (d == "bilibili.com" || d.hasSuffix(".bilibili.com")) && (c.expiresDate == nil || c.expiresDate! > Date())
    }
    func restore() async {
        guard !restored else { return };restored=true
        guard let data=CredentialVault.read(), let saved=try? JSONDecoder().decode([SavedCookie].self,from:data) else { return }
        let cookies=saved.compactMap(\.cookie).filter(Self.trusted)
        for cookie in cookies { await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) }
        await update(cookies)
    }
    func completeLogin() async {
        generation=UUID();let ticket=generation
        busy=true; defer { busy=false }
        let cookies=await WKWebsiteDataStore.default().httpCookieStore.allCookies().filter(Self.trusted)
        await update(cookies)
        guard ticket==generation else { return }
        guard loggedIn else { message="尚未检测到登录，请在官方页面完成登录后再点击。"; return }
        do { try CredentialVault.save(JSONEncoder().encode(cookies.map(SavedCookie.init))) }
        catch { message=error.localizedDescription }
    }
    private func update(_ cookies:[HTTPCookie]) async {
        let ticket=generation
        // API requests target api.bilibili.com; do not forward cookies scoped only to passport/www.
        let scoped=cookies.filter { c in
            let domain=c.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."))
            return (domain=="bilibili.com" || domain=="api.bilibili.com") && c.path=="/"
        }
        await BiliAPI.shared.setCookie(scoped.map { "\($0.name)=\($0.value)" }.joined(separator:"; "))
        do {
            let j=try await BiliAPI.shared.request("/x/web-interface/nav")
            guard ticket==generation else { return }
            guard j["isLogin"].bool else { name="未登录";mid=0;vip=false; return }
            name=j["uname"].string;avatar=j["face"].string; mid=j["mid"].int
            vip=j["vipStatus"].int==1 || j["vip"]["status"].int==1
        } catch { message=error.localizedDescription }
    }
    func acceptLoginCookies(_ incoming:[HTTPCookie]) async throws {
        generation=UUID();let ticket=generation
        var merged:[String:HTTPCookie]=[:]
        for cookie in incoming.filter(Self.trusted) { merged[cookie.domain+"|"+cookie.path+"|"+cookie.name]=cookie }
        let cookies=Array(merged.values)
        guard cookies.contains(where:{$0.name=="SESSDATA"}) else { throw BiliError.invalid("登录响应未包含完整会话，请重试或使用官方网页登录。") }
        await update(cookies)
        guard ticket==generation,loggedIn else { throw BiliError.invalid("登录状态尚未确认，请重试。") }
        for cookie in cookies { await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) }
        try CredentialVault.save(JSONEncoder().encode(cookies.map(SavedCookie.init)))
    }
    func logout() async {
        generation=UUID()
        busy=true; defer { busy=false }
        do { try CredentialVault.delete() } catch { message=error.localizedDescription; return }
        await BiliAPI.shared.setCookie("")
        let store=WKWebsiteDataStore.default()
        let records=await store.dataRecords(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),for:records)
        mid=0;name="未登录";avatar="";vip=false
    }
}
struct OfficialWebPage:NSViewRepresentable {
    let url:URL
    let external:(URL)->Void
    var pageZoom:Double=1
    func makeCoordinator()->Coordinator { Coordinator(external:external) }
    func makeNSView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .default()
        let view=WKWebView(frame:.zero,configuration:config)
        view.navigationDelegate=context.coordinator;view.uiDelegate=context.coordinator;view.pageZoom=pageZoom
        view.load(URLRequest(url:url));return view
    }
    func updateNSView(_ view:WKWebView,context:Context) {}
    final class Coordinator:NSObject,WKNavigationDelegate,WKUIDelegate {
        let external:(URL)->Void
        init(external:@escaping(URL)->Void) { self.external=external }
        func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping @MainActor (WKNavigationActionPolicy)->Void) {
            guard let url=action.request.url else { decisionHandler(.cancel);return }
            let host=url.host?.lowercased() ?? ""
            let trusted=["bilibili.com","geetest.com","biliapi.com"].contains { host==$0 || host.hasSuffix("."+$0) }
            if url.scheme=="https",trusted { decisionHandler(.allow) }
            else { decisionHandler(.cancel);if action.navigationType == .linkActivated,url.scheme=="https" { external(url) } }
        }
        func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for action:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
            if let url=action.request.url,url.scheme=="https" { external(url) };return nil
        }
    }
}

struct OfficialVerificationSheet:View {
    let url:URL,completed:()->Void
    @Environment(AccountSession.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var body:some View {
        VStack(spacing:0) {
            HStack {Text("完成哔哩哔哩官方验证").font(.headline);Spacer();Button("关闭") {dismiss()}}.padding(20)
            Text("请在官方页面自行完成验证，随后返回原生界面重试。").font(.callout).foregroundStyle(.secondary).padding(.bottom,14)
            OfficialWebPage(url:url,external:{openURL($0)},pageZoom:0.85)
            HStack {Spacer();Button("已完成，返回原生界面") {Task {await account.completeLogin();completed();dismiss()}}.buttonStyle(.glassProminent)}.padding(18)
        }.frame(width:1000,height:720)
    }
}
