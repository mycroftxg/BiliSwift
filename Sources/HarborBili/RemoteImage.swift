import SwiftUI
import AppKit
import ImageIO
import CoreImage
import HarborCore

/// 共享图片管线：B 站 CDN 缩略图 + 内存缓存 + 去重下载 + 后台降采样。
/// 之前用 AsyncImage 直接拉原图（单张 150–330 KB），卡片才 300 pt 宽，是列表加载慢的主因。
@MainActor
final class RemoteImageStore {
    static let shared=RemoteImageStore()
    private let cache=NSCache<NSString,NSImage>()
    private var colors:[String:NSColor]=[:]
    private var inflight:[String:Task<NSImage?,Never>]=[:]
    private let session:URLSession
    private init() {
        let config=URLSessionConfiguration.default
        config.urlCache=URLCache(memoryCapacity:64<<20,diskCapacity:512<<20,diskPath:"harbor-images")
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpMaximumConnectionsPerHost=8
        config.timeoutIntervalForRequest=20
        session=URLSession(configuration:config)
        cache.countLimit=800
        cache.totalCostLimit=256<<20
    }
    func image(_ raw:String,width:Int,height:Int?=nil) async -> NSImage? {
        let primary=Self.sizedURL(raw,width:width,height:height)
        if let image=await load(primary,maxPixel:max(width*2,320)) { return image }
        if let original=URL(string:Video.secure(raw)),original != primary { return await load(original,maxPixel:max(width*2,320)) }
        return nil
    }
    /// 同步查缓存：滚动回看时不闪占位、不重复起任务。
    func cached(_ raw:String,width:Int,height:Int?=nil)->NSImage? {
        guard let url=Self.sizedURL(raw,width:width,height:height) else { return nil }
        return cache.object(forKey:url.absoluteString as NSString)
    }
    private func load(_ url:URL?,maxPixel:Int) async -> NSImage? {
        guard let url else { return nil }
        let key=url.absoluteString
        if let hit=cache.object(forKey:key as NSString) { return hit }
        if let running=inflight[key] { return await running.value }
        let session=self.session
        let task=Task<NSImage?,Never> {
            var request=URLRequest(url:url)
            request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
            request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
            guard let data=try? await session.data(for:request).0 else { return nil }
            let decoded=await Task.detached(priority:.userInitiated) { Self.downsample(data,maxPixel:maxPixel) }.value
            guard let cg=decoded?.image else { return nil }
            return NSImage(cgImage:cg,size:NSSize(width:cg.width,height:cg.height))
        }
        inflight[key]=task
        let image=await task.value
        inflight[key]=nil
        if let image { cache.setObject(image,forKey:key as NSString,cost:max(1,Int(image.size.width*image.size.height*4))) }
        return image
    }
    func pixelSize(_ raw:String,width:Int=720) async -> CGSize? {
        guard let image=await image(raw,width:width) else { return nil }
        return image.size
    }
    /// 取图片的平均色（用于把封面颜色映射成环境光，而不是放大图片本身）。
    /// 取图像下部区域的平均色并适度提饱和度，避免整图平均后发灰。
    func averageColor(_ raw:String,crop:CGFloat=0.5) async -> NSColor? {
        let secure=Video.secure(raw)
        guard !secure.isEmpty else { return nil }
        let key=secure+"|c\(Int(crop*100))"
        if let hit=colors[key] { return hit }
        guard let image=await image(raw,width:64),
              let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { return nil }
        let context=CIContext(options:[.workingColorSpace:CGColorSpaceCreateDeviceRGB()])
        // CI 坐标原点在左下：取底部 crop 比例的区域（人物/主视觉通常在这里）。
        let height=CGFloat(cg.height)*crop
        guard let filter=CIFilter(name:"CIAreaAverage",parameters:[kCIInputImageKey:CIImage(cgImage:cg),kCIInputExtentKey:CIVector(x:0,y:0,z:CGFloat(cg.width),w:height)]),
              let output=filter.outputImage else { return nil }
        var pixel=[UInt8](repeating:0,count:4)
        context.render(output,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        var color=NSColor(srgbRed:CGFloat(pixel[0])/255,green:CGFloat(pixel[1])/255,blue:CGFloat(pixel[2])/255,alpha:1)
        var hue:CGFloat=0,saturation:CGFloat=0,brightness:CGFloat=0,alpha:CGFloat=0
        color.getHue(&hue,saturation:&saturation,brightness:&brightness,alpha:&alpha)
        color=NSColor(hue:hue,saturation:min(1,max(0.4,saturation*1.5)),brightness:min(1,brightness*1.12),alpha:1)
        colors[key]=color
        return color
    }
    /// hdslb 支持 `@<宽>w_<高>h_1c.webp` 裁剪与 `@<宽>w.webp` 等比缩放。
    nonisolated static func sizedURL(_ raw:String,width:Int,height:Int?=nil) -> URL? {
        let secure=Video.secure(raw)
        guard !secure.isEmpty else { return nil }
        let host=URL(string:secure)?.host?.lowercased() ?? ""
        let resizable=host=="hdslb.com" || host.hasSuffix(".hdslb.com")
        if resizable,!secure.contains("@"),!secure.contains("?") {
            let w=max(96,min(width,1920))
            if let height { return URL(string:secure+"@\(w)w_\(max(96,min(height,1080)))h_1c.webp") }
            return URL(string:secure+"@\(w)w.webp")
        }
        return URL(string:secure)
    }
    private struct Decoded:@unchecked Sendable { let image:CGImage }
    nonisolated private static func downsample(_ data:Data,maxPixel:Int)->Decoded? {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil) else { return nil }
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,
                                   kCGImageSourceCreateThumbnailWithTransform:true,
                                   kCGImageSourceShouldCacheImmediately:true,
                                   kCGImageSourceThumbnailMaxPixelSize:max(64,maxPixel)]
        guard let cg=CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { return nil }
        return Decoded(image:cg)
    }
}

/// 替换 AsyncImage：按显示尺寸取缩略图、命中缓存立即返回、滚动复用不重复下载。
struct RemoteImage:View {
    let source:String
    var width:Int=720
    var square:Bool=false
    var showsPlaceholderIcon:Bool=true
    var fit:Bool=false
    @State private var image:NSImage?
    var body:some View {
        Group {
            if let cached=RemoteImageStore.shared.cached(source,width:width,height:square ? width:nil) {
                Image(nsImage:cached).resizable().modifier(ImageFit(fit:fit))
            } else if let image {
                Image(nsImage:image).resizable().modifier(ImageFit(fit:fit))
            } else {
                Rectangle().fill(.quaternary).overlay {
                    if showsPlaceholderIcon,!square { Image(systemName:"play.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
                }
            }
        }.clipped()
        .task(id:source) {
            guard image==nil, !source.isEmpty else { return }
            image=await RemoteImageStore.shared.image(source,width:width,height:square ? width:nil)
        }
    }
}

private struct ImageFit:ViewModifier {
    let fit:Bool
    func body(content:Content)->some View { fit ? AnyView(content.scaledToFit()):AnyView(content.scaledToFill()) }
}
