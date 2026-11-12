import Testing
import Foundation
@testable import HarborCore

@Test func webEnvelopeAndSearchTitle() throws {
    let json=try JSONDecoder().decode(JSON.self,from:Data(#"{"bvid":"BV123","aid":42,"title":"<em class=\"keyword\">Swift</em> &amp; macOS","pic":"//i0.hdslb.com/a.jpg","duration":"12:30","owner":{"name":"UP","mid":7},"stat":{"view":12345}}"#.utf8))
    let video=Video(json)
    #expect(video.title=="Swift & macOS")
    #expect(video.cover=="https://i0.hdslb.com/a.jpg")
    #expect(video.durationLabel=="12:30")
    #expect(video.viewLabel=="1.2 万播放")
}
@Test func signingIsCanonicalAndFiltersReservedCharacters() throws {
    let key=try WBI.key(image:"7cd084941338484aae1ad9425b84077c",sub:"4932caff0ff746eab6f01bf08b70ac45")
    #expect(key.count==32)
    let signed=WBI.sign(["keyword":"测试!'()*","page":"1"],key:key,timestamp:1700000000)
    #expect(signed["keyword"]=="测试")
    #expect(signed["wts"]=="1700000000")
    #expect(signed["w_rid"]?.count==32)
    #expect(WBI.query(["z":"a b","a":"中"])=="a=%E4%B8%AD&z=a%20b")
    #expect(throws:BiliError.self) { try WBI.key(image:"short",sub:"key") }
}
@Test func mediaRangesRejectMalformedInput() throws {
    #expect(try ByteSpan("10-19")==ByteSpan(offset:10,length:10))
    #expect(throws:BiliError.self) { try ByteSpan("20-10") }
    #expect(throws:BiliError.self) { try ByteSpan("0-") }
    #expect(!MediaTrack.allowedHost("bilivideo.com.attacker.example"))
    #expect(MediaTrack.allowedHost("upos-sz-mirrorcos.bilivideo.com"))
}
private func sidx(version:UInt8=0,nested:Bool=false)->Data {
    var bytes:[UInt8]=[]
    func put(_ number:UInt64,_ count:Int) { for i in (0..<count).reversed() { bytes.append(UInt8((number >> (i*8)) & 255)) } }
    let size=version==0 ? 56:64
    put(UInt64(size),4);bytes += Array("sidx".utf8)
    bytes += [version,0,0,0];put(1,4);put(1000,4)
    put(0,version==0 ? 4:8);put(10,version==0 ? 4:8)
    put(0,2);put(2,2)
    put(nested ? 0x80000064:100,4);put(2000,4);put(0,4)
    put(200,4);put(3000,4);put(0,4)
    return Data(bytes)
}
@Test func sidxAbsoluteOffsetsAndDurations() throws {
    let segments=try SegmentIndex.parse(sidx(),absoluteOffset:1000)
    #expect(segments==[MediaSegment(span:ByteSpan(offset:1066,length:100),duration:2),MediaSegment(span:ByteSpan(offset:1166,length:200),duration:3)])
    let v1=try SegmentIndex.parse(sidx(version:1),absoluteOffset:500)
    #expect(v1[0].span.offset==574)
}
@Test func malformedAndNestedIndexesFailClosed() {
    #expect(throws:BiliError.self) { try SegmentIndex.parse(Data([0,0,0,99,115,105,100,120]),absoluteOffset:0) }
    #expect(throws:BiliError.self) { try SegmentIndex.parse(sidx(nested:true),absoluteOffset:0) }
    #expect(throws:BiliError.self) { try SegmentIndex.parse(sidx().dropLast(),absoluteOffset:0) }
}
@Test func danmakuXMLAndExternalEntities() {
    let data=Data(#"<i><d p="2.5,1,25,16777215,0,0,user,1">你好 &amp; Swift</d><d p="1,5,25,255">置顶</d><d p="bad">忽略</d></i>"#.utf8)
    let items=DanmakuParser.parse(data)
    #expect(items.count==2)
    #expect(items[0].time==1)
    #expect(items[1].text=="你好 & Swift")
    #expect(DanmakuParser.parse(Data("<i><d".utf8)).isEmpty)
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1")) func liveGuestAPI() async throws {
    guard ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"]=="1" else { return }
    let api=BiliAPI()
    let videos=try await api.popular()
    #expect(!videos.isEmpty)
    let video=try #require(videos.first)
    let detail=try await api.detail(video.bvid)
    #expect(detail["bvid"].string==video.bvid)
    let cid=try #require(detail["pages"].array.first?["cid"].int)
    let manifest=try await api.playback(video.bvid,cid:cid)
    #expect(!manifest.video.isEmpty)
    #expect(!manifest.audio.isEmpty)
    let track=try #require(manifest.video.first)
    var request=URLRequest(url:track.url)
    request.setValue(track.index.header,forHTTPHeaderField:"Range")
    request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
    let (data,response)=try await URLSession.shared.data(for:request)
    #expect((response as? HTTPURLResponse)?.statusCode==206)
    #expect(!(try SegmentIndex.parse(data,absoluteOffset:track.index.offset)).isEmpty)
    let results=try await api.search("Swift")
    #expect(!results.isEmpty)
}

@Test func rangeOverflowDoesNotTrap() {
    #expect(throws:BiliError.self) { try ByteSpan("0-18446744073709551615") }
}
@Test func advancedFormatsRemainSeparateAndBackupHostsAreRestricted() throws {
    let json=try JSONDecoder().decode(JSON.self,from:Data(#"{"timelength":10000,"support_formats":[{"new_description":"杜比视界"}],"dash":{"video":[{"id":126,"codecs":"dvh1.05.06","baseUrl":"https://cache.bilivideo.cn:8082/video.m4s","backupUrl":["https://evil.example/video.m4s","https://cdn.bilivideo.com/video.m4s"],"SegmentBase":{"Initialization":"0-99","indexRange":"100-199"}}],"audio":[{"id":30280,"codecs":"mp4a.40.2","baseUrl":"https://cdn.bilivideo.com/audio.m4s","SegmentBase":{"Initialization":"0-99","indexRange":"100-199"}}],"dolby":{"audio":[{"id":30250,"codecs":"ec-3","baseUrl":"https://cdn.bilivideo.com/dolby.m4s","SegmentBase":{"Initialization":"0-99","indexRange":"100-199"}}]},"flac":{"audio":{"id":30251,"codecs":"fLaC","baseUrl":"https://cdn.bilivideo.com/flac.m4s","SegmentBase":{"Initialization":"0-99","indexRange":"100-199"}}}}}"#.utf8))
    let manifest=PlaybackManifest(json)
    #expect(manifest.video.count==1)
    #expect(manifest.audio.count==3)
    let video=try #require(manifest.video.first)
    #expect(video.quality==126)
    #expect(video.advanced)
    #expect(video.url.host=="cdn.bilivideo.com")
    #expect(video.urls.count==2)
    #expect(manifest.audio.filter(\.advanced).count==2)
    let playlist=SegmentIndex.playlist(track:video,segments:[MediaSegment(span:ByteSpan(offset:200,length:1000),duration:2.5)],resource:"/secret/video.mp4")
    #expect(playlist.contains("#EXT-X-TARGETDURATION:3"))
    #expect(playlist.contains("#EXT-X-BYTERANGE:1000@200"))
    #expect(playlist.contains("#EXT-X-MAP:URI=\"/secret/video.mp4\",BYTERANGE=\"100@0\""))
    #expect(!playlist.contains("bilivideo"))
}

@Test func visibleDanmakuBoundariesAndDensity() {
    let items=(0..<100).map { Danmaku(id:$0,time:Double($0),text:"弹幕",mode:1,color:0xffffff) }
    #expect(DanmakuParser.active(items,at:10).map(\.id)==Array(4...10))
    #expect(DanmakuParser.active(items,at:10,limit:2).map(\.id)==[9,10])
    #expect(DanmakuParser.active(items,at: -1).isEmpty)
    #expect(DanmakuParser.active(items,at: .nan).isEmpty)
    #expect(DanmakuParser.active(items,at:10,limit:0).isEmpty)
}

@Test func officialChannelCatalogUsesDistinctStableIDs() {
    #expect(BiliChannel.all.count>=36)
    #expect(Set(BiliChannel.all.map(\.id)).count==BiliChannel.all.count)
    #expect(BiliChannel.find("douga")?.title=="动画")
    #expect(BiliChannel.find("ai")?.title=="人工智能")
    #expect(BiliChannel.all.allSatisfy { $0.url.scheme=="https" && $0.url.host=="www.bilibili.com" })
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1"))
func nativeQRChallengeUsesOfficialPassport() async throws {
    let client=QRLoginClient()
    let challenge=try await client.generate()
    #expect(["passport.bilibili.com","account.bilibili.com"].contains(URL(string:challenge.url)?.host ?? ""))
    #expect(!challenge.key.isEmpty)
    let result=try await client.poll(challenge)
    #expect(result.code==86101 || result.code==86038)
}

@Test func danmakuCompletesTravelAndNeverEvictsAdmittedItems() throws {
    let long=Danmaku(id:1,time:0,text:String(repeating:"长弹幕",count:30),mode:1,color:0xffffff)
    let burst=(2...80).map {Danmaku(id:$0,time:0.2+Double($0)/100,text:"新弹幕",mode:1,color:0xffffff)}
    let timeline=DanmakuTimeline(comments:[long]+burst,viewport:1000,fontSize:17,density:3,lanes:2)
    let entry=try #require(timeline.items.first)
    #expect(entry.duration>12)
    #expect(abs(entry.centerX(viewport:1000,at:entry.start)-entry.width/2-1000)<0.01)
    #expect(abs(entry.centerX(viewport:1000,at:entry.end)+entry.width/2)<0.01)
    #expect(timeline.active(at:entry.duration/2).contains{$0.id==1})
    #expect(!timeline.active(at:entry.end+0.01).contains{$0.id==1})
    for time in stride(from:0.0,to:entry.end,by:0.1) {#expect(timeline.active(at:time).count<=3)}
    let slower=DanmakuTimeline(comments:[long],viewport:1000,fontSize:17,density:3,lanes:2,speedMultiplier:0.75)
    #expect(try #require(slower.items.first).duration>entry.duration)
}
@Test func creatorSearchRecentVideosRetainAuthorAndSeasonIDs() throws {
    let user=Creator(try JSONDecoder().decode(JSON.self,from:Data(#"{"mid":123,"uname":"<em>UP</em>","upic":"//i0.hdslb.com/a.jpg","fans":99,"videos":2,"res":[{"bvid":"BV1test","title":"稿件","pic":"//i0.hdslb.com/v.jpg","duration":"1:00"}]}"#.utf8)))
    #expect(user.name=="UP")
    #expect(user.recent.first?.author=="UP")
    #expect(user.recent.first?.mid==123)
    let season=Video(season: .object(["season_id":.number(42),"title":.string("<em>剧集</em>"),"cover":.string("https://i0.hdslb.com/a.jpg")]))
    #expect(season.seasonID==42)
    #expect(season.title=="剧集")
    #expect(season.isSeason)
    let decoded=try JSONDecoder().decode(Video.self,from:JSONEncoder().encode(user.recent[0]))
    #expect(decoded==user.recent[0])
    #expect(BiliChannel.all.allSatisfy{$0.regionID != nil || $0.seasonType != nil})
    #expect(BiliChannel.find("douga")?.regionID==1005)
}
@Test func creatorVideosWithCollectionSeasonIDRemainRegularVideos() throws {
    // UP 投稿列表里的 season_id 是合集 ID：BV 稿件不能因此被送进剧集页（会 -404）。
    let video=Video(try JSONDecoder().decode(JSON.self,from:Data(#"{"bvid":"BV1FCps68EGf","aid":117408954062530,"title":"史上最大现金收购案","pic":"//i0.hdslb.com/a.jpg","author":"小Lin说","mid":520819684,"season_id":809657,"length":"12:34","play":38320000}"#.utf8)))
    #expect(!video.isSeason)
    #expect(video.seasonID==809657)
    #expect(video.durationLabel=="12:34")
    #expect(video.viewLabel.contains("万播放"))
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1"))
func nativeChannelAndSearchSources() async throws {
    let api=BiliAPI()
    for id in ["douga","game","ai","music","anime","movie","guochuang","tv","documentary","variety"] {
        let channel=try #require(BiliChannel.find(id))
        let first=try await api.channel(channel)
        #expect(!first.videos.isEmpty)
        #expect(first.videos.allSatisfy{!$0.bvid.isEmpty && !$0.title.isEmpty})
        try await Task.sleep(for:.milliseconds(180))
    }
    let users=try await api.searchResults("小lin",scope:.user)
    #expect(!users["result"].array.isEmpty)
    #expect(!Creator(try #require(users["result"].array.first)).recent.isEmpty)
    let seasons=try await api.searchResults("鬼灭",scope:.bangumi)
    #expect(!seasons["result"].array.isEmpty)
    let season=try await api.season(47836)
    #expect(!season["episodes"].array.isEmpty)
    let lives=try await api.liveRooms()
    #expect(!lives.isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1"))
func nativeCreatorReadOrExplicitVerificationRequirement() async throws {
    let api=BiliAPI()
    let mid=1676992
    do {let info=try await api.creator(mid);#expect(info["mid"].int==mid)}
    catch BiliError.http(let code) where [403,412].contains(code) {#expect([403,412].contains(code));return}
    do {
        let archives=try await api.creatorVideos(mid)
        #expect(!archives["list"]["vlist"].array.isEmpty)
    } catch BiliError.server(let code,_) where [-352,-412].contains(code) {
        // Guest space requests may require the service's interactive verification.
        // This verifies the explicit blocked path; it does not mark archive browsing as verified.
        #expect(code == -352 || code == -412)
    } catch BiliError.http(let code) where [403,412].contains(code) {#expect([403,412].contains(code))}
    let collections=try await api.creatorCollections(mid)
    #expect(collections["items_lists"]["page"]["total"].int>=0)
}
