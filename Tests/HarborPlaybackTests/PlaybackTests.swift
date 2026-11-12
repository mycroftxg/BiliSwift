import Foundation
import Testing
import AVFoundation
import SwiftUI
import HarborCore
@testable import HarborBili

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1"))
@MainActor func realDASHThroughLocalHLSAndAVPlayer() async throws {
    let api=BiliAPI()
    let video=try #require(try await api.popular().first)
    let detail=try await api.detail(video.bvid)
    let cid=try #require(detail["pages"].array.first?["cid"].int)
    let manifest=try await api.playback(video.bvid,cid:cid)
    let track=try #require(manifest.video.filter { $0.codec.hasPrefix("avc1") && $0.quality<=80 }.max { $0.quality < $1.quality })
    let audio=try #require(manifest.audio.filter { $0.codec.hasPrefix("mp4a") }.first)
    let gateway=MediaGateway()
    do {
        let url=try await gateway.prepare(video:track,audio:audio)
        #expect(url.host=="127.0.0.1")
        let (master,response)=try await URLSession.shared.data(from:url)
        #expect((response as? HTTPURLResponse)?.statusCode==200)
        #expect(String(decoding:master,as:UTF8.self).contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        let wrong=url.deletingLastPathComponent().appendingPathComponent("unknown.m3u8")
        let (_,notFound)=try await URLSession.shared.data(from:wrong)
        #expect((notFound as? HTTPURLResponse)?.statusCode==404)
        let player=AVPlayer(url:url)
        player.isMuted=true // Automated verification must not play audible content.
        player.play()
        var progressed=false
        for _ in 0..<100 {
            try await Task.sleep(for:.milliseconds(250))
            if player.currentItem?.status == .failed { throw player.currentItem?.error ?? BiliError.invalid("AVPlayer failed") }
            if player.currentTime().seconds>1 { progressed=true;break }
        }
        #expect(progressed)
        let item=try #require(player.currentItem)
        #expect(item.status == .readyToPlay)
        #expect(item.duration.seconds>1)
        let mediaTypes=item.tracks.compactMap { $0.assetTrack?.mediaType }
        #expect(mediaTypes.contains(.audio))
        #expect(mediaTypes.contains(.video))
        #expect(item.presentationSize.width>0)
        await player.seek(to:CMTime(seconds:10,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
        #expect(abs(player.currentTime().seconds-10)<2)
        player.pause()
        #expect(player.rate==0)
        player.replaceCurrentItem(with:nil)
        await gateway.stop()
    } catch { await gateway.stop();throw error }
}

@Test @MainActor func sidebarPreferencesPersistAndReorder() throws {
    let name="HarborTests."+UUID().uuidString
    let defaults=try #require(UserDefaults(suiteName:name))
    defer { defaults.removePersistentDomain(forName:name) }
    let preferences=AppPreferences(defaults:defaults)
    preferences.values.appearance="dark"
    preferences.values.volume=0.4
    preferences.toggleChannel("ai",true)
    #expect(preferences.channels.last?.id=="ai")
    preferences.moveChannel("ai",by: -1)
    #expect(preferences.channels.dropLast().last?.id=="ai")
    let restored=AppPreferences(defaults:defaults)
    #expect(restored.values.appearance=="dark")
    #expect(restored.values.volume==0.4)
    #expect(restored.values.channelIDs==preferences.values.channelIDs)
    restored.toggleChannel("ai",false)
    #expect(!restored.values.channelIDs.contains("ai"))
    restored.toggleChannel("invalid-channel",true)
    #expect(!restored.values.channelIDs.contains("invalid-channel"))
    restored.reset()
    #expect(restored.values==PreferenceValues())
}
@Test @MainActor func qualityMenuGroupsCodecsWithoutLosingPreferences() throws {
    let j=try JSONDecoder().decode(JSON.self,from:Data(#"{"dash":{"video":[{"id":80,"codecs":"avc1.640032","baseUrl":"https://cdn.bilivideo.com/v1","SegmentBase":{"Initialization":"0-9","indexRange":"10-19"}},{"id":80,"codecs":"hvc1.1.6.L120","baseUrl":"https://cdn.bilivideo.com/v2","SegmentBase":{"Initialization":"0-9","indexRange":"10-19"}},{"id":64,"codecs":"avc1.640032","baseUrl":"https://cdn.bilivideo.com/v3","SegmentBase":{"Initialization":"0-9","indexRange":"10-19"}}]}}"#.utf8))
    let name="HarborTests."+UUID().uuidString
    let defaults=try #require(UserDefaults(suiteName:name))
    defer { defaults.removePersistentDomain(forName:name) }
    let p=PlaybackController()
    let preferences=AppPreferences(defaults:defaults)
    p.preferences=preferences;p.manifest=PlaybackManifest(j)
    #expect(p.qualityOptions.count==2)
    #expect(p.qualityOptions.first?.codec.hasPrefix("avc1")==true)
    preferences.values.codec="hevc"
    #expect(p.qualityOptions.first?.codec.hasPrefix("hvc1")==true)
}

@Test @MainActor func immersivePlayerFillsWideAndTallContainers() throws {
    let name="HarborTests."+UUID().uuidString
    let defaults=try #require(UserDefaults(suiteName:name))
    defer { defaults.removePersistentDomain(forName:name) }
    let prefs=AppPreferences(defaults:defaults)
    for size in [CGSize(width:1200,height:700),CGSize(width:900,height:850)] {
        let view=PlayerPanel(immersive:true)
            .environment(PlaybackController()).environment(prefs).environment(WindowPresentation())
            .frame(width:size.width,height:size.height).background(Color.red)
        let renderer=ImageRenderer(content:view);renderer.scale=1
        let image=try #require(renderer.cgImage)
        #expect(image.width==Int(size.width))
        #expect(image.height==Int(size.height))
        var pixels=[UInt8](repeating:0,count:image.width*image.height*4)
        let context=try #require(CGContext(data:&pixels,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(origin:.zero,size:size))
        // A red sentinel surrounds the player. It must never appear at either edge.
        // ImageRenderer cannot render AVPlayerLayer itself, so inspect layout coverage, not video pixels.
        for x in [4,image.width-5] {
            let offset=(image.height/2*image.width+x)*4
            #expect(pixels[offset+3]==255)
            #expect(!(pixels[offset]>240 && pixels[offset+1]<10 && pixels[offset+2]<10))
        }
    }
}

@Test @MainActor func preferenceMigrationPreservesExistingSettings() throws {
    let old=Data(#"{"appearance":"dark","volume":0.35,"channelIDs":["music","ai"]}"#.utf8)
    let values=try JSONDecoder().decode(PreferenceValues.self,from:old)
    #expect(values.appearance=="dark")
    #expect(values.volume==0.35)
    #expect(values.channelIDs==["music","ai"])
    #expect(values.danmakuSpeed==1)
    #expect(values.resume)
}
@Test @MainActor func videoCardsUseUniformThumbnailAndTextSlots() throws {
    let video=Video(.object(["bvid":.string("BVtest"),"title":.string("测试标题"),"author":.string("UP"),"duration":.number(60)]))
    for width in [240.0,300.0] {
        let renderer=ImageRenderer(content:VideoCard(video:video).frame(width:width))
        renderer.scale=1
        let image=try #require(renderer.cgImage)
        #expect(image.width==Int(width))
        #expect(abs(Double(image.height)-(width*9/16+72))<20)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_LIVE_TESTS"] == "1"))
@MainActor func nativePGCAndLiveHLSRoutes() async throws {
    let api=BiliAPI()
    let season=try await api.season(47836)
    let episode=try #require(season["episodes"].array.first)
    let manifest=try await api.playback(episode["bvid"].string,cid:episode["cid"].int,episodeID:episode["id"].int)
    #expect(!manifest.encrypted)
    #expect(!manifest.video.isEmpty)
    #expect(!manifest.audio.isEmpty)
    let rooms=try await api.liveRooms()
    let room=try #require(rooms.first?.roomID)
    let stream=try await api.liveStream(room)
    let gateway=MediaGateway()
    do {
        let url=try await gateway.prepareLive(stream.url)
        let (data,response)=try await URLSession.shared.data(from:url)
        #expect((response as? HTTPURLResponse)?.statusCode==200)
        let playlist=String(decoding:data,as:UTF8.self)
        #expect(playlist.hasPrefix("#EXTM3U"))
        #expect(!playlist.contains("https://"))
        let player=AVPlayer(url:url);player.isMuted=true;player.play()
        var progressed=false
        for _ in 0..<80 {
            try await Task.sleep(for:.milliseconds(250))
            if player.currentItem?.status == .failed {throw BiliError.invalid("原生直播解码失败")}
            if player.currentTime().seconds>0.5 {progressed=true;break}
        }
        #expect(progressed)
        player.pause();player.replaceCurrentItem(with:nil)
        await gateway.stop()
    } catch {await gateway.stop();throw error}
}

@Test func closedGatewayRejectsNewWorkWithoutInvalidSessionTasks() async throws {
    let gateway=MediaGateway()
    try await gateway.start()
    await gateway.stop()
    do {try await gateway.start();Issue.record("已关闭的网关不应重新接收请求")}
    catch is CancellationError {}
}

@Test func liveChatHeartbeatMatchesWebPacket() {
    let body=Data("[object Object]".utf8)
    let expectedHeader:[UInt8]=[0,0,0,31,0,16,0,1,0,0,0,2,0,0,0,1]
    #expect(LiveChat.packet(op:2,body:body)==Data(expectedHeader)+body)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["HARBOR_CHAT_ROOM"] != nil))
@MainActor func realLiveChatReceivesMessage() async throws {
    let roomID=try #require(Int(ProcessInfo.processInfo.environment["HARBOR_CHAT_ROOM"] ?? ""))
    var received=false
    var status=""
    let chat=LiveChat(onStatus:{ status=$0 }) { _,_,_ in received=true }
    defer { chat.disconnect() }
    try await chat.connect(roomID:roomID)
    for _ in 0..<100 {
        if received || status.contains("失败") { break }
        try await Task.sleep(for:.milliseconds(200))
    }
    #expect(received, "直播间聊天状态：\(status)")
}

@Test @MainActor func tmdbArtworkRejectsPartialAndAmbiguousMatches() {
    let results: [[String: Any]] = [
        ["name": "伍六七", "first_air_date": "2024-01-01", "id": 1],
        ["name": "伍六七之记忆碎片", "first_air_date": "2020-01-01", "id": 2],
        ["name": "伍六七之记忆碎片", "first_air_date": "2024-10-02", "id": 3]
    ]
    let title = "伍六七之记忆碎片"
    #expect(TMDBPosters.matchingTitle(in: results, title: title, year: 2024)?["id"] as? Int == 3)
    #expect(TMDBPosters.matchingTitle(in: results, title: title, year: nil) == nil)
    #expect(TMDBPosters.matchingTitle(in: Array(results.prefix(2)), title: title, year: 2024) == nil)
}

@Test func updaterRejectsTamperedMirrorDownload() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let digest = try #require(UpdateController.sha256(from:
        "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ))
    try Data("abc".utf8).write(to: file)
    try UpdateController.verify(file, size: 3, digest: digest)
    try Data("abd".utf8).write(to: file)
    #expect(throws: BiliError.self) {
        try UpdateController.verify(file, size: 3, digest: digest)
    }
    #expect(throws: BiliError.self) {
        try UpdateController.verify(file, size: 4, digest: digest)
    }
}
