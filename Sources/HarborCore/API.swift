import Foundation

public actor BiliAPI {
    public static let shared = BiliAPI()
    private var cookie = ""
    private var mixin: String?
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }
    public func setCookie(_ value: String) { cookie = value; mixin = nil }
    public func cookieHeader() -> String { cookie }
    public func cookieValue(_ name:String) -> String? {
        for part in cookie.split(separator:";") {
            let pieces=part.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard pieces.count==2 else { continue }
            if pieces[0].trimmingCharacters(in:.whitespaces)==name { return String(pieces[1]) }
        }
        return nil
    }
    public func csrf() -> String { cookie.split(separator: ";").compactMap { part -> String? in
        let pieces = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        return pieces.count == 2 && pieces[0] == "bili_jct" ? String(pieces[1]) : nil
    }.first ?? "" }
    public func request(_ path: String, _ parameters: [String: String] = [:], post: Bool = false, signed: Bool = false,host:String="api.bilibili.com") async throws -> JSON {
        guard ["api.bilibili.com","api.live.bilibili.com"].contains(host) else {throw BiliError.invalid("不受信任的接口主机")}
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?") else { throw BiliError.invalid("无效接口路径") }
        var params = parameters
        if signed {
            if mixin == nil {
                let nav = try await request("/x/web-interface/nav")
                func stem(_ value: String) -> String { URL(string: value)?.deletingPathExtension().lastPathComponent ?? "" }
                mixin = try WBI.key(image: stem(nav["wbi_img"]["img_url"].string), sub: stem(nav["wbi_img"]["sub_url"].string))
            }
            params = WBI.sign(params, key: mixin!)
        }
        if post {
            guard !csrf().isEmpty else { throw BiliError.loginRequired }
            params["csrf"] = csrf(); params["csrf_token"] = csrf()
        }
        var components = URLComponents(string: "https://"+host+path)!
        if !post { components.percentEncodedQuery = WBI.query(params) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = post ? "POST" : "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let referer:String
        if host == "api.live.bilibili.com" {
            referer = "https://live.bilibili.com/" + (path == "/msg/send" ? (parameters["roomid"] ?? "") : "")
        }
        else if path.hasPrefix("/x/space/") || path.hasPrefix("/x/polymer/web-space/") {referer="https://space.bilibili.com/"+(parameters["mid"] ?? parameters["vmid"] ?? "")}
        else if path.contains("/search/") {referer="https://search.bilibili.com/"}
        else if path.hasPrefix("/x/v2/reply"),parameters["type"]=="17" {referer="https://t.bilibili.com/"}
        else {referer="https://www.bilibili.com/"}
        request.setValue(referer,forHTTPHeaderField:"Referer")
        request.setValue(host=="api.live.bilibili.com" ? "https://live.bilibili.com":"https://www.bilibili.com", forHTTPHeaderField: "Origin")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if post { request.httpBody = Data(WBI.query(params).utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let http=response as? HTTPURLResponse else {throw BiliError.invalid("无效服务器响应")}
        guard (200..<300).contains(http.statusCode) else {throw BiliError.http(http.statusCode)}
        let root = try JSONDecoder().decode(JSON.self, from: data)
        let code = root["code"].int
        // nav returns signing keys even when logged out.
        guard code == 0 || (path == "/x/web-interface/nav" && code == -101) else {
            if code == -403 || code == -352 { mixin = nil }
            throw BiliError.server(code, root["message"].string)
        }
        if case .null = root["data"] { return root["result"] }
        return root["data"]
    }
    /// 首页推荐流（与网页版同源），带 freshen 参数才会换一批。
    public func homeFeed(page:Int=1,fresh:Int=0) async throws -> [Video] {
        let data=try await request("/x/web-interface/wbi/index/top/feed/rcmd",[
            "web_location":"1430650","y_num":"4","fresh_type":"4","feed_version":"V8",
            "fresh_idx":"\(fresh)","fresh_idx_1h":"\(fresh)","fetch_row":"1","brush":"\(page)",
            "homepage_ver":"1","ps":"30"],signed:true)
        return data["item"].array.map { Video($0) }
    }
    public func popular(page: Int = 1) async throws -> [Video] {
        try await request("/x/web-interface/popular", ["pn": "\(page)", "ps":"24"])["list"].array.map { Video($0) }
    }
    public func search(_ text: String, page: Int = 1) async throws -> [Video] {
        try await request("/x/web-interface/wbi/search/type", ["search_type":"video", "keyword":text, "page":"\(page)"], signed: true)["result"].array.map { Video($0) }.filter { !$0.bvid.isEmpty }
    }
    public func detail(_ bvid: String) async throws -> JSON { try await request("/x/web-interface/view", ["bvid":bvid]) }
    public func playback(_ bvid: String, cid: Int, quality: Int = 127,episodeID:Int?=nil) async throws -> PlaybackManifest {
        if let episodeID {
            let data=try await request("/pgc/player/web/v2/playurl",["ep_id":"\(episodeID)","cid":"\(cid)","qn":"\(quality)","fnval":"4048","fnver":"0","fourk":"1"])
            let info=data["video_info"]
            if info["code"].int != 0 { throw BiliError.server(info["code"].int,info["message"].string) }
            return PlaybackManifest(info["dash"]["video"].array.isEmpty ? data:info)
        }
        return PlaybackManifest(try await request("/x/player/wbi/playurl", ["bvid":bvid,"cid":"\(cid)","qn":"\(quality)","fnval":"4048","fnver":"0","fourk":"1"], signed:true))
    }
    public func channel(_ channel:BiliChannel,page:Int=1,fresh:Int=0) async throws -> (videos:[Video],hasMore:Bool) {
        if let type=channel.seasonType {
            // 每次取 3 页（72 条），按评分 + 追番/追剧热度重排；
            // 刷新时轮换起始页（共 8 个窗口，每次前进 3 页），保证内容真的会变。
            let window=((max(fresh,1)-1)%8)*3
            let first=window+(max(page,1)-1)*3+1
            var items:[JSON]=[]
            var hasNext=false
            for index in first..<(first+3) {
                let data=try await request("/pgc/season/index/result",["season_type":"\(type)","type":"1","st":"\(type)","page":"\(index)","pagesize":"24","order":"3","sort":"0"])
                items += data["list"].array
                hasNext=data["has_next"].int==1
                if !hasNext { break }
            }
            var seen=Set<Int>()
            var unique:[JSON]=[]
            for item in items {
                let id=item["season_id"].int
                guard id>0,seen.insert(id).inserted else { continue }
                unique.append(item)
            }
            let ranked=unique.sorted { pgcRank($0)>pgcRank($1) }
            return (ranked.map { Video(season:$0) },hasNext)
        }
        guard let region=channel.regionID,region>0 else { throw BiliError.invalid("该分区尚未提供可用的视频目录") }
        do {
            let data=try await request("/x/web-interface/region/feed/rcmd",["display_id":"\(page)","request_cnt":"15","from_region":"\(region)","device":"web","plat":"30","fresh_idx":"\(fresh)","fresh_type":"3"],signed:true)
            let videos=data["archives"].array.map { Video($0) }
            return (videos,!videos.isEmpty)
        } catch BiliError.server(let code,_) where code==62013 { return ([],false) }
    }
    /// PGC 综合排序：评分优先，热度（追番/追剧人数）做次级权重。
    private func pgcRank(_ item:JSON)->Double {
        let rating=Double(item["score"].string) ?? item["score"].double
        let heat=Self.chineseCount(item["order"].string)
        return rating*10 + (heat>0 ? log10(heat+1):0)
    }
    private static func chineseCount(_ text:String)->Double {
        var value=text;var unit=1.0
        if value.contains("亿") { unit=100_000_000;value=value.replacingOccurrences(of:"亿",with:"") }
        else if value.contains("万") { unit=10_000;value=value.replacingOccurrences(of:"万",with:"") }
        let number=Double(value.filter { $0.isNumber || $0=="." }) ?? 0
        return number*unit
    }
    public func season(_ id:Int) async throws -> JSON { try await request("/pgc/view/web/season",["season_id":"\(id)"]) }
    public func searchSuggestions(_ term: String) async throws -> [String] {
        var components = URLComponents(string: "https://s.search.bilibili.com/main/suggest")!
        components.queryItems = [.init(name: "term", value: term)]
        var request = URLRequest(url: components.url!)
        request.setValue("https://search.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiliError.invalid("搜索联想暂不可用")
        }
        let root = try JSONDecoder().decode(JSON.self, from: data)
        var seen = Set<String>()
        return root["result"]["tag"].array.map { $0["value"].string }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func searchResults(_ text:String,scope:SearchScope,page:Int=1,order:String="totalrank") async throws -> JSON {
        var parameters=["search_type":scope.parameter,"keyword":text,"page":"\(page)"]
        if scope == .all || scope == .video {parameters["order"]=order}
        if scope == .user {parameters["order"]="fans";parameters["order_sort"]="0"}
        return try await request("/x/web-interface/wbi/search/type",parameters,signed:true)
    }
    public func creator(_ mid:Int) async throws -> JSON {
        do {
            var info=try await request("/x/space/wbi/acc/info",["mid":"\(mid)"],signed:true)
            // acc/info 有时不带头图（或字段为空），用 card.space.l_img 补齐。
            if info["top_photo"].string.isEmpty,let card=try? await creatorCard(mid),!card["top_photo"].string.isEmpty,
               case .object(var map)=info {
                map["top_photo"]=card["top_photo"]
                info = .object(map)
            }
            return info
        }
        catch BiliError.server(let code,_) where [-352,-412,-403].contains(code) {return try await creatorCard(mid)}
        catch BiliError.http(let code) where [403,412].contains(code) {return try await creatorCard(mid)}
    }
    private func creatorCard(_ mid:Int) async throws -> JSON {
        let data=try await request("/x/web-interface/card",["mid":"\(mid)","photo":"true"])
        guard case .object(var card)=data["card"] else {throw BiliError.invalid("UP 主资料暂不可用")}
        card["top_photo"] = .string(data["space"]["l_img"].string.isEmpty ? data["space"]["s_img"].string:data["space"]["l_img"].string);card["level"]=data["card"]["level_info"]["current_level"];card["official"]=data["card"]["Official"]
        return .object(card)
    }
    public func creatorVideos(_ mid:Int,page:Int=1,order:String="pubdate") async throws -> JSON {
        try await request("/x/space/wbi/arc/search",["mid":"\(mid)","pn":"\(page)","ps":"30","order":order],signed:true)
    }
    public func creatorCollections(_ mid:Int,page:Int=1) async throws -> JSON {
        try await request("/x/polymer/web-space/seasons_series_list",["mid":"\(mid)","page_num":"\(page)","page_size":"20"])
    }
    public func collectionVideos(_ collection:CreatorCollection,page:Int=1) async throws -> JSON {
        if collection.series {
            return try await request("/x/series/archives",["mid":"\(collection.mid)","series_id":"\(collection.collectionID)","pn":"\(page)","ps":"30","sort":"desc","only_normal":"true"])
        }
        return try await request("/x/polymer/web-space/seasons_archives_list",["mid":"\(collection.mid)","season_id":"\(collection.collectionID)","page_num":"\(page)","page_size":"30","sort_reverse":"false"])
    }
    public func liveRooms(page:Int=1) async throws -> [Video] {
        let data=try await request("/room/v1/room/get_user_recommend",["page":"\(page)"],host:"api.live.bilibili.com")
        return data.array.map {Video(room:$0)}
    }
    public func liveRoom(_ id:Int) async throws -> JSON {try await request("/room/v1/Room/get_info",["room_id":"\(id)"],host:"api.live.bilibili.com")}
    public func liveStream(_ id:Int,qn:Int?=nil) async throws -> LiveStream {
        let data=try await request("/xlive/web-room/v2/index/getRoomPlayInfo",["room_id":"\(id)","protocol":"0,1","format":"0,1,2","codec":"0,1","qn":qn.map(String.init) ?? "10000","platform":"web","ptype":"8"],host:"api.live.bilibili.com")
        let playurl=data["playurl_info"]["playurl"]
        var qualities=playurl["g_qn_desc"].array.map { LiveQuality(id:$0["qn"].int,label:$0["desc"].string.isEmpty ? "\($0["qn"].int)P":$0["desc"].string) }
        var current=playurl["g_qn"].int
        // 收集全部可用 HLS 候选（不同 CDN 节点 / 编码），播放失败时逐个回退。
        var candidates:[URL]=[]
        var seen=Set<String>()
        for stream in playurl["stream"].array where stream["protocol_name"].string=="http_hls" {
            for format in stream["format"].array {
                for codec in format["codec"].array where ["avc","hevc"].contains(codec["codec_name"].string) {
                    if qualities.isEmpty { qualities=codec["accept_qn"].array.map { LiveQuality(id:$0.int,label:"\($0.int)P") } }
                    if current==0 { current=codec["current_qn"].int }
                    for info in codec["url_info"].array {
                        guard let url=URL(string:info["host"].string+codec["base_url"].string+info["extra"].string),
                              url.scheme=="https",MediaTrack.allowedHost(url.host),
                              !seen.contains(url.absoluteString) else { continue }
                        seen.insert(url.absoluteString);candidates.append(url)
                    }
                }
            }
        }
        guard !candidates.isEmpty else { throw BiliError.invalid("直播间暂未返回兼容的 HLS 直播流，可能尚未开播或需要账号权限。") }
        return LiveStream(urls:Array(candidates.prefix(6)),qualities:qualities.sorted { $0.id>$1.id },current:current)
    }
    /// 当前登录账号资料（含自己空间头图）。
    public func myInfo() async throws -> JSON { try await request("/x/space/myinfo") }
    public func sendLiveDanmaku(roomID: Int, text: String) async throws {
        guard roomID > 0 else { throw BiliError.invalid("无效的直播间 ID") }
        guard let sessionCookie = cookieValue("SESSDATA"), !sessionCookie.isEmpty else {
            throw BiliError.loginRequired
        }
        _ = try await request("/msg/send", [
            "roomid": String(roomID),
            "msg": text,
            "rnd": String(Int(Date().timeIntervalSince1970)),
            "bubble": "0",
            "color": "16777215",
            "fontsize": "25",
            "mode": "1"
        ], post: true, host: "api.live.bilibili.com")
    }
    /// 直播弹幕服务器信息（token + host list）。
    public func liveDanmuInfo(_ roomID:Int) async throws -> JSON {
        try await request("/xlive/web-room/v1/index/getDanmuInfo",["id":"\(roomID)","type":"0","web_location":"444.8"],signed:true,host:"api.live.bilibili.com")
    }
    /// 我的关注列表。
    public func followings(_ mid:Int,page:Int=1) async throws -> JSON {
        try await request("/x/relation/followings",["vmid":"\(mid)","pn":"\(page)","ps":"30","order":"desc"])
    }
    /// 消息中心：reply / at / like，需要登录 Cookie。
    public func msgFeed(_ kind:String) async throws -> JSON {
        try await request("/x/msgfeed/\(kind)",["platform":"web","web_location":"333.40164"])
    }
    public func replies(aid:Int,root:Int,page:Int=1) async throws -> JSON {
        try await request("/x/v2/reply/reply",["type":"1","oid":"\(aid)","root":"\(root)","pn":"\(page)","ps":"20"])
    }
    public func related(_ bvid: String) async throws -> [Video] { try await request("/x/web-interface/archive/related", ["bvid":bvid]).array.map { Video($0) } }
    public func dynamics(offset:String="") async throws -> JSON {
        try await request("/x/polymer/web-dynamic/v1/feed/all",["type":"all","offset":offset,"page":"1","features":"itemOpusStyle"])
    }
    public func comments(oid:Int,type:Int=1,page:Int=1) async throws -> JSON {
        try await request("/x/v2/reply",["type":"\(type)","oid":"\(oid)","pn":"\(page)","sort":"2"])
    }
    public func dynamicComments(oid:Int,next:Int=0) async throws -> JSON {
        try await request("/x/v2/reply/main",["type":"17","oid":"\(oid)","mode":"3","next":"\(next)","ps":"20","plat":"1","web_location":"333.999"],signed:true)
    }
    public func comments(aid: Int, page: Int = 1) async throws -> JSON { try await comments(oid:aid,type:1,page:page) }
    public func heartbeat(bvid: String, cid: Int, seconds: Int) async throws {
        _ = try await request("/x/click-interface/web/heartbeat", ["bvid":bvid,"cid":"\(cid)","played_time":"\(seconds)","play_type":"1","type":"3"],post:true)
    }
    public func subtitleInfo(bvid: String, cid: Int) async throws -> JSON { try await request("/x/player/wbi/v2",["bvid":bvid,"cid":"\(cid)"],signed:true) }
}
