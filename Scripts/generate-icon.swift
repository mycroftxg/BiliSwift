import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main struct IconTool {
    static let pink=Color(red:0.984,green:0.447,blue:0.600)
    static let deepPink=Color(red:0.910,green:0.290,blue:0.478)
    static let blue=Color(red:0.000,green:0.631,blue:0.839)

    @MainActor static func main() throws {
        guard CommandLine.arguments.count==2 else { return }
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (name,pixels) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
            let renderer=ImageRenderer(content:
                ZStack {
                    RoundedRectangle(cornerRadius:225)
                        .fill(LinearGradient(colors:[pink,deepPink,blue],startPoint:.topLeading,endPoint:.bottomTrailing))
                    // 电视天线
                    Capsule().fill(.white).frame(width:26,height:200).rotationEffect(.degrees(-34)).offset(x:-128,y:-242)
                    Capsule().fill(.white).frame(width:26,height:200).rotationEffect(.degrees(34)).offset(x:128,y:-242)
                    // 电视主体
                    RoundedRectangle(cornerRadius:104,style:.continuous)
                        .fill(.white)
                        .frame(width:580,height:400)
                        .offset(y:52)
                        .shadow(color:.black.opacity(0.18),radius:26,y:14)
                    RoundedRectangle(cornerRadius:74,style:.continuous)
                        .fill(LinearGradient(colors:[Color.white.opacity(0.9),pink.opacity(0.18)],startPoint:.top,endPoint:.bottom))
                        .frame(width:492,height:312)
                        .offset(y:58)
                    // 眼睛
                    Capsule().fill(deepPink).frame(width:64,height:76).offset(x:-118,y:48)
                    Capsule().fill(deepPink).frame(width:64,height:76).offset(x:118,y:48)
                    // 播放三角
                    PlayShape().fill(blue).frame(width:74,height:86).offset(y:196)
                }.frame(width:1024,height:1024)
            )
            renderer.scale=Double(pixels)/1024
            guard let image=renderer.cgImage,let destination=CGImageDestinationCreateWithURL(folder.appendingPathComponent(name+".png") as CFURL,UTType.png.identifier as CFString,1,nil) else { continue }
            CGImageDestinationAddImage(destination,image,nil)
            if !CGImageDestinationFinalize(destination) { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

struct PlayShape:Shape {
    func path(in rect:CGRect)->Path {
        var path=Path()
        path.move(to:CGPoint(x:rect.midX-rect.width*0.34,y:rect.minY))
        path.addLine(to:CGPoint(x:rect.midX+rect.width*0.5,y:rect.midY))
        path.addLine(to:CGPoint(x:rect.midX-rect.width*0.34,y:rect.maxY))
        path.closeSubpath()
        return path
    }
}
