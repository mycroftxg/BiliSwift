import SwiftUI
import HarborCore

extension JSON {
    /// 评论接口会在用到表情时返回 emote 映射：[名称] -> 图片 URL。
    var commentEmoteURLs:[String:String] {
        guard case .object(let map)=self["emote"] else { return [:] }
        var result:[String:String]=[:]
        for (name,value) in map {
            let url=value["url"].string
            if !url.isEmpty { result[name]=Video.secure(url) }
        }
        return result
    }

    /// 评论正文附带的图片（新版为 pictures 数组，旧版可能是单张 picture）。
    var commentPictureURLs:[String] {
        var urls:[String]=[]
        for item in self["pictures"].array {
            let src=item["img_src"].string
            if !src.isEmpty { urls.append(Video.secure(src)) }
        }
        if urls.isEmpty {
            let single=self["picture"].string
            if !single.isEmpty { urls.append(Video.secure(single)) }
        }
        return urls
    }
}

/// 评论图片缩略图 + 点击大图预览。
struct CommentPictures:View {
    let urls:[String]
    private struct Preview:Identifiable { let id:String;let url:String }
    @State private var preview:Preview?

    var body:some View {
        HStack(spacing:6) {
            ForEach(Array(urls.prefix(3).enumerated()),id:\.offset) { _,url in
                Button { preview=Preview(id:url,url:url) } label:{
                    CoverImage(source:url,width:240,showsPlaceholderIcon:false)
                        .frame(width:84,height:84)
                        .clipShape(.rect(cornerRadius:8))
                        .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.08),lineWidth:1) }
                }.buttonStyle(.plain)
            }
        }
        .sheet(item:$preview) { item in
            ZStack {
                Color.black.ignoresSafeArea()
                RemoteImage(source:item.url,width:1600,showsPlaceholderIcon:false,fit:true)
                    .padding(24)
                VStack { HStack { Spacer();Button { preview=nil } label:{ Image(systemName:"xmark").font(.system(size:14,weight:.semibold)).frame(width:32,height:32) }.buttonStyle(.glass).buttonBorderShape(.circle).padding(16) };Spacer() }
            }
            .frame(minWidth:640,minHeight:480)
            .environment(\.colorScheme,.dark)
        }
    }
}


/// 把 `[表情]` 渲染成 B 站表情图片，其余文字原样保留。
struct CommentTextView:View {
    let text:String
    let emotes:[String:String]
    var font:Font = .callout
    var color:Color = .white
    @State private var images:[String:NSImage]=[:]

    var body:some View {
        content
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal:false,vertical:true)
            .task(id:text) { await loadEmotes() }
    }

    private var content:Text {
        var result=Text("")
        for token in Self.tokens(text) {
            if emotes[token] != nil,let image=images[token] {
                result = result + Text(Image(nsImage:image)).baselineOffset(-2)
            } else {
                result = result + Text(token)
            }
        }
        return result
    }

    private func loadEmotes() async {
        var loaded=images
        for (name,url) in emotes where loaded[name] == nil {
            guard let image=await RemoteImageStore.shared.image(url,width:72) else { continue }
            loaded[name]=Self.inlineImage(image)
        }
        if loaded.count != images.count { images=loaded }
    }

    private static func inlineImage(_ image:NSImage)->NSImage {
        let height:CGFloat=16
        let width=max(10,min(32,image.size.width*height/max(1,image.size.height)))
        let target=NSImage(size:NSSize(width:width,height:height))
        target.lockFocus()
        image.draw(in:NSRect(x:0,y:0,width:width,height:height))
        target.unlockFocus()
        return target
    }

    private static func tokens(_ value:String)->[String] {
        var out:[String]=[];var current=""
        for ch in value {
            if ch=="[" {
                if !current.isEmpty { out.append(current) };current="["
            } else if ch=="]" && current.hasPrefix("[") {
                current.append(ch);out.append(current);current=""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
