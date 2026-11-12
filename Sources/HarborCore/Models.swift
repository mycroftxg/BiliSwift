import Foundation
import CryptoKit

public enum JSON: Codable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    public var string: String { switch self { case .string(let v): return v; case .number(let v): return String(Int64(v)); default: return "" } }
    public var int: Int { Int(double) }
    public var double: Double { switch self { case .number(let v): return v; case .string(let v): return Double(v) ?? 0; default: return 0 } }
    public var bool: Bool { if case .bool(let v) = self { return v }; return int != 0 }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
}

public enum BiliError: LocalizedError, Sendable {
    case server(Int, String), http(Int), invalid(String), loginRequired
    public var errorDescription: String? {
        switch self {
        case .http(let status): return [403,412].contains(status) ? "服务要求完成官方验证（HTTP \(status)）":"接口暂时不可用（HTTP \(status)）"
        case .server(let code, let message): return "\(message)（\(code)）"
        case .invalid(let message): return message
        case .loginRequired: return "请先登录哔哩哔哩账号。"
        }
    }
}
public struct Video: Identifiable, Codable, Hashable, Sendable {
    public var id: String { bvid }
    public let roomID:Int?
    public let seasonID:Int?
    public let episodeID:Int?
    public let bvid: String, aid: Int, title: String, cover: String, author: String, mid: Int, duration: String, views: Int
    public init(_ j: JSON) {
        roomID=j["room_id"].int>0 ? j["room_id"].int:nil
        seasonID = j["season_id"].int>0 ? j["season_id"].int:nil
        episodeID = j["ep_id"].int>0 ? j["ep_id"].int:nil
        bvid = j["bvid"].string
        let rawAid=j["aid"].int
        // 推荐流里部分条目只有 id（就是 aid），没有 aid 字段。
        aid = rawAid != 0 ? rawAid:(bvid.hasPrefix("BV") ? j["id"].int:0)
        title = j["title"].string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
        let pic = j["pic"].string.isEmpty ? j["cover"].string : j["pic"].string
        cover = Self.secure(pic)
        author = j["owner"]["name"].string.isEmpty ? (j["author"]["name"].string.isEmpty ? j["author"].string:j["author"]["name"].string) : j["owner"]["name"].string
        mid = j["owner"]["mid"].int == 0 ? (j["author"]["mid"].int==0 ? j["mid"].int:j["author"]["mid"].int) : j["owner"]["mid"].int
        let length = j["duration"].string.isEmpty ? j["length"].string : j["duration"].string
        duration = length
        views = j["stat"]["view"].int == 0 ? j["play"].int : j["stat"]["view"].int
    }
    public init(season j:JSON) {
        roomID=nil;seasonID=j["season_id"].int;episodeID=nil
        bvid="ss"+j["season_id"].string;aid=0;mid=0;views=0
        title=Creator.plain(j["title"].string.isEmpty ? j["season_title"].string:j["title"].string)
        cover=Self.secure(j["cover"].string.isEmpty ? j["first_ep"]["cover"].string:j["cover"].string)
        author=j["index_show"].string
        duration=j["badge"].string
    }
    public init(room j:JSON) {
        roomID=j["roomid"].int==0 ? j["room_id"].int:j["roomid"].int;seasonID=nil;episodeID=nil
        bvid="live\(roomID ?? 0)";aid=0
        title=Creator.plain(j["title"].string)
        cover=Self.secure(j["user_cover"].string.isEmpty ? (j["cover"].string.isEmpty ? j["system_cover"].string:j["cover"].string):j["user_cover"].string)
        author=Creator.plain(j["uname"].string);mid=j["uid"].int
        duration="直播";views=j["online"].int
    }
    public static func episode(_ j:JSON,seasonID:Int,seasonTitle:String)->Video {
        .init(.object(["bvid":j["bvid"],"aid":j["aid"],"title":.string(seasonTitle+" · "+(j["show_title"].string.isEmpty ? j["title"].string+" "+j["long_title"].string:j["show_title"].string)),"pic":j["cover"],"author":.string("哔哩哔哩"),"duration":.number(j["duration"].double/1000),"season_id":.number(Double(seasonID)),"ep_id":j["id"]]))
    }
    public static func secure(_ value: String) -> String {
        if value.isEmpty { return value }
        if value.hasPrefix("//") { return "https:" + value }
        if value.hasPrefix("bfs/") || value.hasPrefix("space/") { return "https://i0.hdslb.com/" + value }
        if !value.contains("://"),value.hasPrefix("/") { return "https://i0.hdslb.com" + value }
        return value.replacingOccurrences(of: "http://", with: "https://")
    }
    /// 只有 PGC 剧集（bvid 形如 ss123）才走剧集详情；普通投稿里的 season_id 是 UP 合集 ID。
    public var isSeason: Bool { bvid.hasPrefix("ss") }
    public var durationLabel: String {
        if roomID != nil {return "直播"};if duration.contains(":") || isSeason && episodeID==nil { return duration }
        let n = Int(duration) ?? 0; return String(format: "%d:%02d", n / 60, n % 60)
    }
    public var viewLabel: String { if roomID != nil {return views>=10000 ? String(format:"%.1f 万人气",Double(views)/10000):"\(views) 人气"};if isSeason { return "哔哩哔哩" };return views >= 10000 ? String(format: "%.1f 万播放", Double(views) / 10000) : "\(views) 播放" }
}
public struct Episode: Identifiable, Sendable {
    public var id: Int { cid }
    public let cid: Int, title: String, page: Int
    public let video:Video?
    public init(_ j: JSON) { cid = j["cid"].int; title = j["part"].string; page = j["page"].int;video=nil }
    public init(video:Video,cid:Int,title:String,page:Int) {self.video=video;self.cid=cid;self.title=title;self.page=page}
}
public struct LiveQuality:Identifiable,Sendable,Hashable {
    public let id:Int,label:String
    public init(id:Int,label:String){self.id=id;self.label=label}
}
public struct LiveStream:Sendable {
    public let urls:[URL],qualities:[LiveQuality],current:Int
    public var url:URL { urls[0] }
    public init(urls:[URL],qualities:[LiveQuality],current:Int){self.urls=urls;self.qualities=qualities;self.current=current}
}
public struct ByteSpan: Sendable, Equatable {
    public let offset: UInt64, length: UInt64
    public init(offset: UInt64, length: UInt64) { self.offset = offset; self.length = length }
    public init(_ text: String) throws {
        let values = text.split(separator: "-").compactMap { UInt64($0) }
        guard values.count == 2, values[1] >= values[0], values[1] - values[0] < UInt64.max else { throw BiliError.invalid("无效媒体字节范围") }
        offset = values[0]; length = values[1] - values[0] + 1
    }
    public var header: String { "bytes=\(offset)-\(offset + (length - 1))" }
}
public struct MediaTrack: Identifiable, Sendable {
    public let id: String, quality: Int, codec: String, bandwidth: Int, width: Int, height: Int
    public let url: URL, urls: [URL], initialization: ByteSpan, index: ByteSpan
    public let audio: Bool, label: String
    public init(_ j: JSON, audio: Bool, label: String = "") throws {
        let source = j["baseUrl"].string.isEmpty ? j["base_url"].string : j["baseUrl"].string
        let backups = j["backupUrl"].array + j["backup_url"].array
        var candidates = ([source] + backups.map(\.string)).compactMap { URL(string: Video.secure($0)) }
            .filter { $0.scheme == "https" && Self.allowedHost($0.host) }
        // Prefer the API's standard CDN mirrors over peer-cache endpoints on alternate ports.
        candidates.sort { a,b in
            let ap = a.port == nil || a.port == 443
            let bp = b.port == nil || b.port == 443
            return ap && !bp
        }
        guard let url = candidates.first else { throw BiliError.invalid("无效或不受信任的媒体地址") }
        urls = Array(Set(candidates)).sorted { a,b in
            if a == url { return b != url }; if b == url { return false }
            return a.absoluteString < b.absoluteString
        }
        let seg = j["SegmentBase"]["Initialization"].string.isEmpty ? j["segment_base"] : j["SegmentBase"]
        let initial = seg["Initialization"].string.isEmpty ? seg["initialization"].string : seg["Initialization"].string
        let indexText = seg["indexRange"].string.isEmpty ? seg["index_range"].string : seg["indexRange"].string
        self.url = url; initialization = try ByteSpan(initial); index = try ByteSpan(indexText)
        quality = j["id"].int; codec = j["codecs"].string; bandwidth = j["bandwidth"].int
        width = j["width"].int; height = j["height"].int; self.audio = audio
        self.label = label.isEmpty ? Self.qualityName(quality, audio: audio) : label
        id = "\(audio)-\(quality)-\(codec)"
    }
    public static func allowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["bilivideo.com", "bilivideo.cn", "biliapi.net", "bilibili.com", "akamaized.net", "szbdyd.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    public static func qualityName(_ id: Int, audio: Bool) -> String {
        if audio { return [30216: "64 kbps", 30232: "132 kbps", 30280: "192 kbps", 30250: "杜比全景声", 30251: "Hi-Res"][id] ?? "音轨 \(id)" }
        return [6:"240P",16:"360P",32:"480P",64:"720P",74:"720P 60",80:"1080P",112:"1080P 高码率",116:"1080P 60",120:"4K",125:"HDR",126:"杜比视界",127:"8K" ][id] ?? "画质 \(id)"
    }
    public var advanced: Bool { [125,126,30250,30251].contains(quality) }
}
public struct PlaybackManifest: Sendable {
    public let video: [MediaTrack], audio: [MediaTrack], duration: Double
    public let advertised: [String], preview: Bool, encrypted:Bool
    public init(_ j: JSON) {
        video = j["dash"]["video"].array.compactMap { try? MediaTrack($0, audio: false) }
        var tracks = j["dash"]["audio"].array.compactMap { try? MediaTrack($0, audio: true) }
        tracks += j["dash"]["dolby"]["audio"].array.compactMap { try? MediaTrack($0, audio: true) }
        if let flac = try? MediaTrack(j["dash"]["flac"]["audio"], audio: true) { tracks.append(flac) }
        audio = tracks
        duration = j["timelength"].double / 1000
        advertised = j["support_formats"].array.map { $0["new_description"].string.isEmpty ? $0["display_desc"].string : $0["new_description"].string }
        encrypted=j["is_drm"].bool || j["drm_tech_type"].int>0
        preview = j["is_preview"].bool || j["is_preview"].int == 1
    }
}
public enum WBI {
    private static let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
    public static func key(image: String, sub: String) throws -> String {
        let text = Array(image + sub)
        guard text.count == 64 else { throw BiliError.invalid("WBI 密钥格式已变化") }
        return String(table.prefix(32).map { text[$0] })
    }
    public static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? ""
    }
    public static func query(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { "\(encode($0))=\(encode(parameters[$0]!))" }.joined(separator: "&")
    }
    public static func sign(_ parameters: [String: String], key: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> [String: String] {
        var values = parameters.mapValues { String($0.filter { !"!'()*".contains($0) }) }
        values["wts"] = String(timestamp)
        values["w_rid"] = Insecure.MD5.hash(data: Data((query(values) + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return values
    }
}
