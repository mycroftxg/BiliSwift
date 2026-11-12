import Foundation

public struct Danmaku:Identifiable,Sendable {
    public let id:Int,time:Double,text:String,mode:Int,color:UInt32
    public init(id:Int,time:Double,text:String,mode:Int,color:UInt32) { self.id=id;self.time=time;self.text=text;self.mode=mode;self.color=color }
}
public enum DanmakuParser {
    public static func parse(_ data:Data)->[Danmaku] {
        let delegate=Delegate();let parser=XMLParser(data:data)
        parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse() else { return [] }
        return delegate.items.sorted { $0.time < $1.time }
    }
    /// Visible standard comments, using binary search on the sorted timeline.
    public static func active(_ items:[Danmaku],at time:Double,limit:Int=32)->[Danmaku] {
        guard time.isFinite,limit>0 else { return [] }
        func upper(_ value:Double)->Int {
            var low=0,high=items.count
            while low<high { let middle=(low+high)/2;if items[middle].time<=value { low=middle+1 } else { high=middle } }
            return low
        }
        let start=upper(time-7),end=upper(time)
        guard start<end else { return [] }
        return Array(items[max(start,end-limit)..<end])
    }
    private final class Delegate:NSObject,XMLParserDelegate {
        var items:[Danmaku]=[],attributes:[String]=[],text="",inside=false
        func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes attributeDict:[String:String]) {
            if elementName=="d" { inside=true;text="";attributes=(attributeDict["p"] ?? "").components(separatedBy:",") }
        }
        func parser(_ parser:XMLParser,foundCharacters string:String) { if inside { text += string } }
        func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {
            guard elementName=="d" else { return };inside=false
            if attributes.count>=4,let time=Double(attributes[0]),let mode=Int(attributes[1]),[1,2,3,4,5,6].contains(mode),let color=UInt32(attributes[3]),time>=0,time.isFinite,!text.isEmpty,items.count<50000 {
                items.append(Danmaku(id:items.count,time:time,text:String(text.prefix(200)),mode:mode,color:color))
            }
        }
    }
}
public struct SubtitleCue:Identifiable,Sendable {
    public let id:Int,from:Double,to:Double,text:String
    public init(id:Int,json:JSON) { self.id=id;from=json["from"].double;to=json["to"].double;text=json["content"].string }
}
