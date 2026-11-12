import SwiftUI
import HarborCore

/// 官方网页一律交给系统默认浏览器，App 内不再内嵌浏览器窗口。
struct OfficialModule:View {
    let destination:Destination,mid:Int
    var channel:BiliChannel?=nil
    @Environment(\.openURL) private var openURL
    private var choices:[(String,String)] {
        if let channel { return [(channel.title,channel.address)] }
        return switch destination {
        case .shows: [("番剧","https://www.bilibili.com/anime/"),("国创","https://www.bilibili.com/guochuang/"),("电影","https://www.bilibili.com/movie/"),("电视剧","https://www.bilibili.com/tv/"),("纪录片","https://www.bilibili.com/documentary/")]
        case .live: [("直播","https://live.bilibili.com/")]
        case .messages: [("消息","https://message.bilibili.com/")]
        case .following: [("我的关注",mid>0 ? "https://space.bilibili.com/\(mid)/relation/follow":"https://passport.bilibili.com/login")]
        case .space: [("个人空间",mid>0 ? "https://space.bilibili.com/\(mid)":"https://passport.bilibili.com/login")]
        case .channels: [("分区","https://www.bilibili.com/"),("动画","https://www.bilibili.com/c/douga/"),("游戏","https://www.bilibili.com/c/game/"),("音乐","https://www.bilibili.com/c/music/"),("知识","https://www.bilibili.com/c/knowledge/")]
        default: [("哔哩哔哩","https://www.bilibili.com/")]
        }
    }
    private var url:URL { URL(string:choices.first?.1 ?? "https://www.bilibili.com/")! }
    var body:some View {
        VStack(spacing:14) {
            Image(systemName:"safari").font(.system(size:44)).foregroundStyle(.secondary)
            Text("已在默认浏览器打开").font(.title3.weight(.semibold))
            if choices.count>1 { Text("可用栏目："+choices.map(\.0).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:10) {
                Button("再次打开 ↗") { openURL(url) }.buttonStyle(.glassProminent)
                if choices.count>1 { Menu("切换栏目") { ForEach(choices.indices,id:\.self) { i in Button(choices[i].0) { openURL(URL(string:choices[i].1)!) } } } }
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
