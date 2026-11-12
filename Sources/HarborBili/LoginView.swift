import SwiftUI
import CoreImage.CIFilterBuiltins
import HarborCore

struct LoginSheet:View {
    @Environment(AccountSession.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var web=false
    @State private var refreshID=UUID()
    @State private var image:CGImage?
    @State private var phase="正在获取二维码…"
    @State private var expired=false
    @State private var failure:String?
    @State private var client=QRLoginClient()
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Label("登录哔哩哔哩",systemImage:"person.crop.circle").font(.headline)
                Spacer()
                Button { dismiss() } label:{ Image(systemName:"xmark").frame(width:20,height:20) }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("关闭登录")
            }.padding(22)
            if web {
                HStack { Button("返回扫码登录") { web=false };Spacer();Text("官方登录页面").font(.caption).foregroundStyle(.secondary) }.padding(.horizontal,22).padding(.bottom,12)
                OfficialWebPage(url:URL(string:"https://passport.bilibili.com/login")!,external:{openURL($0)},pageZoom:0.7)
                HStack { if let message=account.message { Text(message).font(.caption).foregroundStyle(.red) };Spacer();Button("已完成登录") { Task { await account.completeLogin();if account.loggedIn { dismiss() } } }.buttonStyle(.glassProminent).disabled(account.busy) }.padding(20)
            } else {
                VStack(spacing:22) {
                    Image(systemName:"play.rectangle.fill").font(.system(size:40)).foregroundStyle(.tint)
                    VStack(spacing:8) { Text("欢迎回来").font(.system(size:28,weight:.bold));Text("使用哔哩哔哩手机客户端扫码登录").font(.callout).foregroundStyle(.secondary) }
                    ZStack {
                        RoundedRectangle(cornerRadius:22).fill(.white)
                        if let image { Image(decorative:image,scale:1).interpolation(.none).resizable().scaledToFit().padding(20) }
                        else { ProgressView().tint(.gray) }
                        if expired { RoundedRectangle(cornerRadius:22).fill(.white.opacity(0.94));Button("刷新二维码") { refreshID=UUID() }.buttonStyle(.glassProminent) }
                    }.frame(width:224,height:224).glassEffect(.regular,in:.rect(cornerRadius:24))
                    Text(failure ?? phase).font(.callout).foregroundStyle(failure==nil ? Color.secondary:Color.red).multilineTextAlignment(.center).frame(maxWidth:360)
                    HStack(spacing:20) {
                        Button("刷新二维码") { refreshID=UUID() }.disabled(image==nil && failure==nil)
                        Button("其他登录方式") { web=true }
                    }.buttonStyle(.plain).foregroundStyle(.tint).font(.callout)
                    Text("在手机端确认后自动完成登录。\n登录凭据只保存在本机钥匙串。")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }.frame(maxWidth:.infinity,maxHeight:.infinity).padding(.bottom,30)
                    .task(id:refreshID) { await runLogin() }
            }
        }.frame(width:web ? 1000:480,height:web ? 720:600)
    }
    private func runLogin() async {
        image=nil;failure=nil;expired=false;phase="正在获取二维码…"
        do {
            let challenge=try await client.generate()
            guard !Task.isCancelled else { return }
            let filter=CIFilter.qrCodeGenerator();filter.message=Data(challenge.url.utf8);filter.correctionLevel="M"
            if let output=filter.outputImage { image=CIContext().createCGImage(output.transformed(by:CGAffineTransform(scaleX:8,y:8)),from:output.extent.applying(CGAffineTransform(scaleX:8,y:8))) }
            phase="打开手机哔哩哔哩，扫一扫"
            while !Task.isCancelled {
                try await Task.sleep(for:.seconds(2))
                let result=try await client.poll(challenge)
                guard !Task.isCancelled else { return }
                switch result.code {
                case 86101: phase="等待扫码"
                case 86090: phase="扫码成功，请在手机上确认"
                case 86038: phase="二维码已过期";expired=true;return
                case 0:
                    phase="正在确认账号…"
                    try await account.acceptLoginCookies(result.cookies)
                    if !Task.isCancelled { dismiss() };return
                default: throw BiliError.server(result.code,result.message)
                }
            }
        } catch is CancellationError {} catch { if !Task.isCancelled { failure=error.localizedDescription } }
    }
}
