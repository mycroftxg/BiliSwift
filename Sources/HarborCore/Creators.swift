import Foundation

public struct Creator:Identifiable,Hashable,Sendable {
    public var id:Int { mid }
    public let mid:Int,name:String,avatar:String,signature:String,fans:Int,videoCount:Int,recent:[Video]
    public init(_ j:JSON) {
        mid=j["mid"].int;name=Self.plain(j["uname"].string.isEmpty ? j["name"].string:j["uname"].string)
        avatar=Video.secure(j["upic"].string.isEmpty ? j["face"].string:j["upic"].string)
        signature=j["usign"].string.isEmpty ? j["sign"].string:j["usign"].string
        fans=j["fans"].int;videoCount=j["videos"].int
        let authorName=name,authorID=mid
        recent=j["res"].array.map { item in
            guard case .object(var object)=item else {return Video(item)}
            object["author"] = .string(authorName);object["mid"] = .number(Double(authorID));return Video(.object(object))
        }
    }
    public init(mid:Int,name:String="UP 主",avatar:String="") {
        self.mid=mid;self.name=name;self.avatar=avatar;signature="";fans=0;videoCount=0;recent=[]
    }
    public static func plain(_ text:String)->String {
        text.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).replacingOccurrences(of:"&amp;",with:"&")
    }
}
public struct CreatorCollection:Identifiable,Hashable,Sendable {
    public var id:String { "\(series ? "series":"season")-\(collectionID)" }
    public let collectionID:Int,mid:Int,title:String,cover:String,series:Bool
    public init(_ j:JSON,mid:Int,series:Bool) {
        self.mid=mid;self.series=series
        collectionID=j["meta"][series ? "series_id":"season_id"].int
        title=j["meta"]["name"].string;cover=Video.secure(j["meta"]["cover"].string)
    }
}
public enum SearchScope:String,CaseIterable,Identifiable,Sendable {
    case all="综合",video="视频",bangumi="番剧",film="影视",live="直播",article="专栏",user="用户"
    public var id:String {rawValue}
    public var parameter:String {
        switch self {case .all,.video:"video";case .bangumi:"media_bangumi";case .film:"media_ft";case .live:"live";case .article:"article";case .user:"bili_user"}
    }
}

public struct CollectionEpisode:Identifiable,Sendable,Hashable {
    public let bvid:String
    public let cid:Int
    public let title:String
    public let cover:String
    public let index:Int
    public var id:String { bvid+"-\(cid)" }
    public init?(_ j:JSON,index:Int) {
        let arc=j["arc"]
        let bvid=j["bvid"].string.isEmpty ? arc["bvid"].string:j["bvid"].string
        guard !bvid.isEmpty else { return nil }
        self.bvid=bvid
        cid=j["cid"].int
        let name=j["title"].string.isEmpty ? arc["title"].string:j["title"].string
        title=name
        cover=Video.secure(arc["pic"].string)
        self.index=index
    }
}
