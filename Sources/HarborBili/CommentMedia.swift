import SwiftUI
import HarborCore

extension JSON {
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
