import Foundation

public struct BiliChannel:Identifiable,Hashable,Sendable {
    public let id:String, title:String, symbol:String, address:String
    public let regionID:Int?,seasonType:Int?
    public init(id:String,title:String,symbol:String,address:String,regionID:Int?=nil,seasonType:Int?=nil) {
        self.id=id;self.title=title;self.symbol=symbol;self.address=address;self.regionID=regionID;self.seasonType=seasonType
    }
    public var url:URL { URL(string:address)! }
    public static let all:[BiliChannel] = [
        .init(id:"anime",title:"番剧",symbol:"play.tv",address:"https://www.bilibili.com/anime/",seasonType:1),
        .init(id:"movie",title:"电影",symbol:"film",address:"https://www.bilibili.com/movie/",seasonType:2),
        .init(id:"guochuang",title:"国创",symbol:"sparkles.tv",address:"https://www.bilibili.com/guochuang/",seasonType:4),
        .init(id:"tv",title:"电视剧",symbol:"tv",address:"https://www.bilibili.com/tv/",seasonType:5),
        .init(id:"variety",title:"综艺",symbol:"star",address:"https://www.bilibili.com/variety/",seasonType:7),
        .init(id:"documentary",title:"纪录片",symbol:"globe.asia.australia",address:"https://www.bilibili.com/documentary/",seasonType:3),
        .init(id:"douga",title:"动画",symbol:"sparkles",address:"https://www.bilibili.com/c/douga/",regionID:1005),
        .init(id:"game",title:"游戏",symbol:"gamecontroller",address:"https://www.bilibili.com/c/game/",regionID:1008),
        .init(id:"kichiku",title:"鬼畜",symbol:"waveform.path",address:"https://www.bilibili.com/c/kichiku/",regionID:1007),
        .init(id:"music",title:"音乐",symbol:"music.note",address:"https://www.bilibili.com/c/music/",regionID:1003),
        .init(id:"dance",title:"舞蹈",symbol:"figure.dance",address:"https://www.bilibili.com/c/dance/",regionID:1004),
        .init(id:"cinephile",title:"影视",symbol:"film.stack",address:"https://www.bilibili.com/c/cinephile/",regionID:1001),
        .init(id:"ent",title:"娱乐",symbol:"party.popper",address:"https://www.bilibili.com/c/ent/",regionID:1002),
        .init(id:"knowledge",title:"知识",symbol:"book",address:"https://www.bilibili.com/c/knowledge/",regionID:1010),
        .init(id:"tech",title:"科技数码",symbol:"desktopcomputer",address:"https://www.bilibili.com/c/tech/",regionID:1012),
        .init(id:"information",title:"资讯",symbol:"newspaper",address:"https://www.bilibili.com/c/information/",regionID:1009),
        .init(id:"food",title:"美食",symbol:"fork.knife",address:"https://www.bilibili.com/c/food/",regionID:1020),
        .init(id:"shortplay",title:"小剧场",symbol:"theatermasks",address:"https://www.bilibili.com/c/shortplay/",regionID:1021),
        .init(id:"car",title:"汽车",symbol:"car",address:"https://www.bilibili.com/c/car",regionID:1013),
        .init(id:"fashion",title:"时尚美妆",symbol:"tshirt",address:"https://www.bilibili.com/c/fashion/",regionID:1014),
        .init(id:"sports",title:"体育运动",symbol:"figure.run",address:"https://www.bilibili.com/c/sports/",regionID:1018),
        .init(id:"animal",title:"动物",symbol:"pawprint",address:"https://www.bilibili.com/c/animal/",regionID:1024),
        .init(id:"vlog",title:"vlog",symbol:"camera",address:"https://www.bilibili.com/c/vlog/",regionID:1029),
        .init(id:"painting",title:"绘画",symbol:"paintbrush",address:"https://www.bilibili.com/c/painting/",regionID:1006),
        .init(id:"ai",title:"人工智能",symbol:"brain",address:"https://www.bilibili.com/c/ai/",regionID:1011),
        .init(id:"home",title:"家装房产",symbol:"house",address:"https://www.bilibili.com/c/home/",regionID:1015),
        .init(id:"outdoors",title:"户外潮流",symbol:"mountain.2",address:"https://www.bilibili.com/c/outdoors/",regionID:1016),
        .init(id:"gym",title:"健身",symbol:"dumbbell",address:"https://www.bilibili.com/c/gym/",regionID:1017),
        .init(id:"handmake",title:"手工",symbol:"scissors",address:"https://www.bilibili.com/c/handmake/",regionID:1019),
        .init(id:"travel",title:"旅游出行",symbol:"airplane",address:"https://www.bilibili.com/c/travel/",regionID:1022),
        .init(id:"rural",title:"三农",symbol:"leaf",address:"https://www.bilibili.com/c/rural/",regionID:1023),
        .init(id:"parenting",title:"亲子",symbol:"figure.2.and.child.holdinghands",address:"https://www.bilibili.com/c/parenting/",regionID:1025),
        .init(id:"health",title:"健康",symbol:"heart",address:"https://www.bilibili.com/c/health/",regionID:1026),
        .init(id:"emotion",title:"情感",symbol:"heart.text.clipboard",address:"https://www.bilibili.com/c/emotion/",regionID:1027),
        .init(id:"life_joy",title:"生活兴趣",symbol:"cup.and.saucer",address:"https://www.bilibili.com/c/life_joy/",regionID:1030),
        .init(id:"life_experience",title:"生活经验",symbol:"lightbulb",address:"https://www.bilibili.com/c/life_experience/",regionID:1031),
    ]
    public static let defaultIDs=["anime","guochuang","movie","tv","documentary","douga","game","music","knowledge","tech","food"]
    public static func find(_ id:String)->BiliChannel? { all.first { $0.id==id } }
}
