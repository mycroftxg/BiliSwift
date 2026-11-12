import Foundation

/// 一条完整动态：图文、视频、转发等共用的表示。
public struct DynamicItem:Identifiable,Sendable,Hashable {
    public let id:String
    public let mid:Int
    public let author:String
    public let avatar:String
    public let time:String
    public let text:String
    public let images:[String]
    public let video:Video?
    public let likes:Int
    public let comments:Int
    public init?(_ j:JSON) {
        let modules=j["modules"]
        let author=modules["module_author"]
        let dynamic=modules["module_dynamic"]
        let major=dynamic["major"]
        let idString=j["id_str"].string.isEmpty ? j["id"].string:j["id_str"].string
        guard !idString.isEmpty else { return nil }
        id=idString
        mid=author["mid"].int
        self.author=author["name"].string
        avatar=author["face"].string
        time=author["pub_time"].string
        let opus=major["opus"]
        var body=dynamic["desc"]["text"].string
        if body.isEmpty { body=opus["summary"]["text"].string }
        if body.isEmpty { body=opus["title"].string }
        text=body
        var pics=major["draw"]["items"].array.map { $0["src"].string }
        if pics.isEmpty { pics=major["opus"]["pics"].array.map { $0["url"].string } }
        images=pics.map(Video.secure)
        let archive=major["archive"]
        if !archive["bvid"].string.isEmpty {
            video=Video(.object(["bvid":archive["bvid"],"aid":archive["aid"],"title":archive["title"],
                                 "pic":archive["cover"],"author":.string(author["name"].string),
                                 "mid":archive["mid"].int != 0 ? archive["mid"]:author["mid"],
                                 "duration":archive["duration_text"],"stat":archive["stat"]]))
        } else { video=nil }
        likes=modules["module_stat"]["like"]["count"].int
        comments=modules["module_stat"]["comment"]["count"].int
    }
}
