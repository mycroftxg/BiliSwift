import SwiftUI
import AVFoundation
import AppKit
import HarborCore

@MainActor @Observable final class PlaybackController {
    @ObservationIgnored let player=AVPlayer()
    @ObservationIgnored private var gateway=MediaGateway()
    @ObservationIgnored private var monitor:Task<Void,Never>?
    private var generation=UUID()
    private var fallbackAttempted=false
    private var refreshAttempted=false
    private var lastPlayableVideo:MediaTrack?
    @ObservationIgnored private var endObserver:NSObjectProtocol?
    init() {
        endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let duration=self.player.currentItem?.duration.seconds ?? 0
                let current=self.player.currentTime().seconds
                guard duration>0,current>=duration-0.5 else { return }
                self.ended=true;self.playing=false;self.seconds=duration
                if self.nextEpisode != nil {
                    withAnimation(.snappy(duration:0.2)) { self.showNextPreview=false }
                    Task { await self.playNextEpisode() }
                }
            }
        }
    }
    /// 从头播放。
    func replay() {
        ended=false
        player.seek(to:.zero)
        player.playImmediately(atRate:rate)
        playing=true
    }
    private var lastPlayableAudio:MediaTrack?
    struct LiveMessage:Identifiable,Sendable,Equatable { public let id:Int;public let user:String;public let text:String }
    var liveMessages:[LiveMessage]=[]
    var liveChatStatus="正在连接直播间聊天…"
    var videoComments:[JSON]=[]
    var commentsAid=0
    var commentsOpen=false
    var showNextPreview=false
    var nextCountdown:Int?
    @ObservationIgnored private var autoNextTask:Task<Void,Never>?
    @ObservationIgnored private var libraryRef:LocalLibrary?
    var currentEpisodeIndex:Int? { episodes.firstIndex { $0.cid == cid } }
    var nextEpisode:Episode? {
        guard let index=currentEpisodeIndex,index+1<episodes.count else { return nil }
        return episodes[index+1]
    }
    var videoTint:Color?
    private var liveURLs:[URL]=[]
    private var liveURLIndex=0
    @ObservationIgnored private var liveChat:LiveChat?
    @ObservationIgnored private var liveChatTask:Task<Void,Never>?
    @ObservationIgnored private var liveTicker:Task<Void,Never>?
    private var liveDanmaku:[Danmaku]=[]
    private var liveSequence=0
    var liveQualities:[LiveQuality]=[]
    var liveQuality:Int=0
    private var liveRoomID:Int?
    var episodes:[Episode]=[]
    private var episodesLoading=false
    var manifest:PlaybackManifest?
    var selectedVideo:MediaTrack?
    var selectedAudio:MediaTrack?
    var seconds:Double=0
    var duration:Double=0
    var rate:Float=1
    var volume:Double=0.8
    var playing=false
    var ended=false
    var loading=false
    var error:String?
    var notice:String?
    var outputStatus="尚未播放"
    var syncStatus="本机续播"
    var danmaku:[Danmaku]=[]
    var subtitles:[SubtitleCue]=[]
    var subtitleChoices:[JSON]=[]
    var subtitleID=""
    var showDanmaku=true
    var danmakuOpacity=0.85
    var video:Video?
    var cid=0
    private var library:LocalLibrary?
    var preferences:AppPreferences?
    var currentLibrary:LocalLibrary? { library }
    var hdrEligible:Bool { AVPlayer.eligibleForHDRPlayback }
    var videoChoices:[MediaTrack] {
        let items=manifest?.video ?? []
        return items.sorted { a,b in a.quality==b.quality ? a.codec < b.codec : a.quality > b.quality }
    }
    var audioChoices:[MediaTrack] { (manifest?.audio ?? []).sorted { $0.bandwidth > $1.bandwidth } }
    var subtitle:String { subtitles.first { $0.from <= seconds && seconds < $0.to }?.text ?? "" }
    func open(video:Video,cid:Int,library:LocalLibrary,episodes:[Episode]=[]) async {
        stop();self.episodes=episodes;self.video=video;self.cid=cid;self.library=library;libraryRef=library;error=nil;notice=nil;outputStatus="正在准备";showNextPreview=false;nextCountdown=nil
        fallbackAttempted=false;refreshAttempted=false;generation=UUID();let ticket=generation
        loading=true;ended=false
        if let values=preferences?.values {
            volume=values.volume;rate=Float(values.rate);showDanmaku=values.danmaku;danmakuOpacity=values.danmakuOpacity
        }
        do {
            if let roomID=video.roomID {
                liveRoomID=roomID
                let stream=try await BiliAPI.shared.liveStream(roomID)
                liveQualities=stream.qualities;liveQuality=stream.current
                liveURLs=stream.urls;liveURLIndex=0
                let url=try await gateway.prepareLive(stream.url)
                guard ticket==generation else {return}
                startLiveChat(roomID:roomID)
                player.replaceCurrentItem(with:AVPlayerItem(url:url));player.volume=Float(volume);player.play();playing=true
                notice="直播播放 · 暂不支持进度拖动";startMonitor(ticket:ticket);return
            }
            let data=try await BiliAPI.shared.playback(video.bvid,cid:cid,episodeID:video.episodeID)
            guard ticket==generation else { return }
            guard !data.encrypted else { throw BiliError.invalid("此片源需要受保护的官方播放链路，当前原生播放器尚不支持。") }
            manifest=data;duration=data.duration
            guard let chosen=compatibleVideo(data.video) else { throw BiliError.invalid("此内容未返回可适配的 DASH 片源，可在官方网页检查权限。") }
            let audio=compatibleAudio(data.audio)
            if audio==nil { throw BiliError.invalid("片源未返回兼容音轨，暂不进行无声播放。") }
            var resume=(preferences?.values.resume ?? true) ? library.progress(video.bvid,cid:cid):0
            if resume==0,(preferences?.values.resume ?? true), let info=try? await BiliAPI.shared.subtitleInfo(bvid:video.bvid,cid:cid),info["last_play_cid"].int==cid {
                resume=max(0,info["last_play_time"].double/1000)
            }
            guard ticket==generation else { return }
            try await configure(video:chosen,audio:audio,position:resume,ticket:ticket)
            guard ticket==generation else { return }
            startMonitor(ticket:ticket)
            Task { await self.loadTimedText(bvid:video.bvid,cid:cid,ticket:ticket) }
            Task { await self.loadComments(video:video) }
            Task {
                if let color=await RemoteImageStore.shared.averageColor(video.cover) { await MainActor.run { self.videoTint=Color(nsColor:color) } }
            }
        } catch is CancellationError {
            if ticket==generation { loading=false }
        } catch { if ticket==generation { self.error=error.localizedDescription;loading=false;outputStatus="未能播放" } }
    }
    var qualityOptions:[MediaTrack] {
        let grouped=Dictionary(grouping:manifest?.video ?? [],by:\.quality)
        return grouped.keys.sorted(by:>).compactMap { quality in
            if let selectedVideo,selectedVideo.quality==quality { return selectedVideo }
            return grouped[quality]?.sorted { codecRank($0.codec)<codecRank($1.codec) }.first
        }
    }
    private func codecRank(_ codec:String,forceCompatible:Bool=false)->Int {
        let preference=forceCompatible ? "auto":preferences?.values.codec ?? "auto"
        if preference=="hevc",codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return -1 }
        if preference != "auto",codec.hasPrefix(preference) { return -1 }
        if codec.hasPrefix("avc1") { return 0 }
        if codec.hasPrefix("hvc1") || codec.hasPrefix("hev1") { return 1 }
        if codec.hasPrefix("av01") { return 2 };return 3
    }
    /// 用户选择的默认高级格式（仅当片源确实提供时生效）。
    private func preferredAdvanced(_ tracks:[MediaTrack])->MediaTrack? {
        let mode=preferences?.values.preferredFormat ?? "auto"
        guard mode != "auto" else { return nil }
        let wanted:Int
        switch mode {
        case "dolbyVision": wanted=126
        case "hdr": wanted=125
        case "uhd": wanted=120
        default: return nil
        }
        let candidates=tracks.filter { $0.quality==wanted && codecRank($0.codec)<3 }
        return candidates.sorted { codecRank($0.codec)<codecRank($1.codec) }.first
    }
    private func compatibleVideo(_ tracks:[MediaTrack],forceCompatible:Bool=false)->MediaTrack? {
        if !forceCompatible,let advanced=preferredAdvanced(tracks) {
            if (advanced.quality==125 || advanced.quality==126),!hdrEligible {
                notice="当前系统未报告可用的 HDR 输出链路，仍按 \(advanced.label) 播放，画面将按 SDR 呈现。"
            }
            return advanced
        }
        let choice=forceCompatible ? "balanced":preferences?.values.quality ?? "balanced"
        let limit=choice=="data" ? 32:choice=="highest" ? 127:80
        let safe=tracks.filter { !$0.advanced && $0.quality<=limit && codecRank($0.codec,forceCompatible:forceCompatible)<3 }
        return safe.sorted { a,b in a.quality==b.quality ? codecRank(a.codec,forceCompatible:forceCompatible)<codecRank(b.codec,forceCompatible:forceCompatible) : a.quality>b.quality }.first
    }
    private func compatibleAudio(_ tracks:[MediaTrack])->MediaTrack? {
        tracks.filter { !$0.advanced && $0.codec.hasPrefix("mp4a") }.max { $0.bandwidth < $1.bandwidth }
    }
    private func configure(video:MediaTrack,audio:MediaTrack?,position:Double,ticket:UUID) async throws {
        loading=true
        let url=try await gateway.prepare(video:video,audio:audio)
        guard generation==ticket,!Task.isCancelled else { return }
        let item=AVPlayerItem(url:url)
        player.replaceCurrentItem(with:item);selectedVideo=video;selectedAudio=audio;ended=false
        player.volume=Float(volume)
        if position>0,position<duration-3 { await player.seek(to:CMTime(seconds:position,preferredTimescale:600)) }
        guard generation==ticket else { return }
        player.playImmediately(atRate:rate);playing=true
        outputStatus="等待系统解码"
    }
    /// 直播弹幕：WebSocket 收到的消息以当前播放时间为时间轴，1 秒合并刷新到弹幕层。
    private func startLiveChat(roomID:Int) {
        LiveLog.write("startLiveChat room=\(roomID)")
        stopLiveChat()
        liveDanmaku=[];liveSequence=0
        liveMessages=[]
        liveChatStatus="正在连接直播间聊天…"
        let chat=LiveChat(onStatus:{ [weak self] in self?.liveChatStatus=$0 }) { [weak self] user,text,color in
            guard let self else { return }
            self.liveDanmaku.append(Danmaku(id:self.liveSequence,time:self.seconds,text:text,mode:1,color:color))
            self.liveMessages.append(LiveMessage(id:self.liveSequence,user:user,text:text))
            self.liveSequence &+= 1
            if self.liveDanmaku.count>240 { self.liveDanmaku.removeFirst(self.liveDanmaku.count-240) }
            if self.liveMessages.count>300 { self.liveMessages.removeFirst(self.liveMessages.count-300) }
        }
        liveChat=chat
        liveChatTask=Task { [weak self] in
            do { try await chat.connect(roomID:roomID) }
            catch {
                guard let self,!Task.isCancelled,self.liveChat === chat else { return }
                self.liveChatStatus="直播间聊天连接失败：\(error.localizedDescription)"
            }
        }
        liveTicker=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(1))
                guard let self,self.liveChat != nil else { return }
                self.danmaku=self.liveDanmaku
            }
        }
    }
    private func stopLiveChat() {
        liveChatTask?.cancel();liveChatTask=nil
        liveChat?.disconnect();liveChat=nil
        liveTicker?.cancel();liveTicker=nil
        liveDanmaku=[];liveMessages=[];liveURLs=[];liveURLIndex=0
    }
    /// 直播源失效时换下一个 CDN/编码候选，全部失败再重新取流。
    func retryLive() async {
        guard liveRoomID != nil else { return }
        while liveURLIndex+1<liveURLs.count {
            liveURLIndex+=1
            if let url=try? await gateway.prepareLive(liveURLs[liveURLIndex]) {
                player.replaceCurrentItem(with:AVPlayerItem(url:url));player.playImmediately(atRate:rate);playing=true
                notice="直播已切换备用线路";return
            }
        }
        if let roomID=liveRoomID,let stream=try? await BiliAPI.shared.liveStream(roomID) {
            liveURLs=stream.urls;liveURLIndex=0;liveQualities=stream.qualities;liveQuality=stream.current
            if let url=try? await gateway.prepareLive(stream.url) {
                player.replaceCurrentItem(with:AVPlayerItem(url:url));player.playImmediately(atRate:rate);playing=true
                notice="直播已重新连接";return
            }
        }
        notice="直播连接失败，请稍后点重试"
    }
    /// 直播画质切换：重新取流并替换播放项，失败时保留当前直播。
    func chooseLiveQuality(_ qn:Int) async {
        guard let roomID=liveRoomID else { return }
        let ticket=generation
        let keepLabel=liveQualities.first { $0.id==liveQuality }?.label ?? "当前画质"
        do {
            let stream=try await BiliAPI.shared.liveStream(roomID,qn:qn)
            let url=try await gateway.prepareLive(stream.url)
            guard ticket==generation else { return }
            liveQualities=stream.qualities;liveQuality=stream.current
            player.replaceCurrentItem(with:AVPlayerItem(url:url));player.playImmediately(atRate:rate);playing=true
            let target=stream.qualities.first { $0.id==qn }?.label ?? "直播画质"
            notice="已更改为 \(target)"
        } catch { notice="更改失败，目前仍以 \(keepLabel) 播放" }
    }
    private func shortLabel(_ label:String)->String {
        if let range=label.range(of:" 高码率") { return String(label[..<range.lowerBound])+"+" }
        if let range=label.range(of:" 60帧") { return String(label[..<range.lowerBound])+"60" }
        if let range=label.range(of:" ") { return String(label[..<range.lowerBound]) }
        return label
    }
    func choose(video:MediaTrack?=nil,audio:MediaTrack?=nil) async {
        guard let current=video ?? selectedVideo else { return }
        if [125,126].contains(current.quality),!hdrEligible {
            notice="当前系统未报告可用的 HDR 输出链路，画面将按 SDR 呈现。"
        }
        let ticket=generation
        let previous=(video:selectedVideo,audio:selectedAudio,position:seconds)
        let keepLabel=shortLabel(audio != nil ? (previous.audio?.label ?? "当前音轨") : (previous.video?.label ?? "当前画质"))
        do { try await configure(video:current,audio:audio ?? selectedAudio,position:seconds,ticket:ticket) }
        catch {
            // 目标片源取流失败时保留原来的播放，不要卡在失败状态。
            loading=false
            notice="更改失败，目前仍以 \(keepLabel) 播放"
            if let old=previous.video,old.id != current.id { try? await configure(video:old,audio:previous.audio,position:previous.position,ticket:generation) }
            return
        }
        if await switchFailed(ticket:ticket) {
            notice="更改失败，目前仍以 \(keepLabel) 播放"
            if let old=previous.video,old.id != current.id { try? await configure(video:old,audio:previous.audio,position:previous.position,ticket:generation) }
            else { await recover(BiliError.invalid("片源无法解码"),ticket:generation) }
        } else {
            notice="已更改为 \(shortLabel(current.label))"
        }
    }
    /// 切换后短暂观察新 item；只有明确 failed 才算失败，慢网络交给 monitor 继续等。
    private func switchFailed(ticket:UUID) async -> Bool {
        guard let item=player.currentItem else { return false }
        var waited=0.0
        while waited<8 {
            if generation != ticket || Task.isCancelled { return false }
            if item.status == .readyToPlay { return false }
            if item.status == .failed { return true }
            try? await Task.sleep(for:.milliseconds(200));waited += 0.2
        }
        return false
    }
    private func startMonitor(ticket:UUID) {
        monitor?.cancel()
        monitor=Task { [weak self] in
            var ticks=0,unreadyTicks=0,stallTicks=0
            while !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
                guard let self,self.generation==ticket,let item=self.player.currentItem else { return }
                let time=self.player.currentTime().seconds
                if time.isFinite { self.seconds=max(0,time) }
                let length=item.duration.seconds;if length.isFinite,length>0 { self.duration=length }
                if self.nextEpisode != nil,length.isFinite,length>0 {
                    let remaining=length-self.seconds
                    if remaining<=20,!self.showNextPreview { withAnimation(.snappy(duration:0.25)) { self.showNextPreview=true } }
                    else if remaining>20,self.showNextPreview,!self.ended { withAnimation(.snappy(duration:0.2)) { self.showNextPreview=false } }
                    // 最后 5 秒显示倒计时，数字与剩余秒数对齐，归零即接下一集。
                    self.nextCountdown = (remaining>0.2 && remaining<=5) ? max(1,Int(ceil(remaining))) : nil
                }
                self.playing=self.player.timeControlStatus == .playing
                self.loading=self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.status == .unknown
                if item.status == .readyToPlay {
                    unreadyTicks=0
                    self.lastPlayableVideo=self.selectedVideo;self.lastPlayableAudio=self.selectedAudio
                    let advanced=self.selectedVideo?.advanced == true || self.selectedAudio?.advanced == true
                    self.outputStatus=advanced ? "系统已就绪 · 高级输出待设备验证" : "系统已就绪 · 兼容播放"
                } else { unreadyTicks += 1 }
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { stallTicks += 1 } else { stallTicks=0 }
                if item.status == .failed || unreadyTicks>100 || stallTicks>120 {
                    await self.recover(item.error ?? BiliError.invalid("媒体加载超时"),ticket:ticket)
                    unreadyTicks=0;stallTicks=0
                    if self.error != nil { return }
                }
                ticks += 1
                if ticks % 20 == 0 { self.persist() }
                if ticks % 100 == 0,(self.preferences?.values.syncHistory ?? true),let video=self.video,video.roomID==nil,self.seconds>0 {
                    let cid=self.cid,time=Int(self.seconds)
                    Task {
                        guard !(await BiliAPI.shared.csrf()).isEmpty else { self.syncStatus="未登录 · 本机续播";return }
                        do {
                            try await BiliAPI.shared.heartbeat(bvid:video.bvid,cid:cid,seconds:time)
                            if self.generation==ticket { self.syncStatus="云端进度已同步" }
                        } catch {
                            if self.generation==ticket { self.syncStatus="云端同步暂不可用 · 已保存在本机" }
                        }
                    }
                }
            }
        }
    }
    private func recover(_ failure:Error,ticket:UUID) async {
        guard ticket==generation else { return }
        if liveRoomID != nil { await retryLive();return }
        if let remembered=lastPlayableVideo,remembered.id != selectedVideo?.id {
            do { try await configure(video:remembered,audio:lastPlayableAudio,position:seconds,ticket:ticket);notice="已回到上一组可播放的片源。";return }
            catch { /* 继续走兼容回退 */ }
        }
        if !fallbackAttempted,let manifest,let compatible=compatibleVideo(manifest.video,forceCompatible:true) {
            fallbackAttempted=true
            notice="所选片源未能播放，正在回退到兼容画质和音轨。"
            do { try await configure(video:compatible,audio:compatibleAudio(manifest.audio),position:seconds,ticket:ticket);return }
            catch { /* refresh signed media URLs once, below */ }
        }
        if !refreshAttempted,let video,video.roomID==nil {
            refreshAttempted=true
            do {
                let refreshed=try await BiliAPI.shared.playback(video.bvid,cid:cid,episodeID:video.episodeID)
                guard ticket==generation else { return }
                manifest=refreshed
                guard let compatible=compatibleVideo(refreshed.video,forceCompatible:true) else { throw failure }
                notice="正在刷新播放地址并恢复进度。"
                try await configure(video:compatible,audio:compatibleAudio(refreshed.audio),position:seconds,ticket:ticket);return
            } catch { /* surface final error */ }
        }
        player.pause();loading=false;playing=false;outputStatus="播放失败";error="播放失败：\(failure.localizedDescription)"
    }
    func toggle() { if player.rate>0 { player.pause() } else { player.playImmediately(atRate:rate) } }
    /// 离开播放界面时立即停声，避免窗口已切走但视频还在后台解码发热。
    func pause() {
        guard player.rate>0 || playing else { return }
        player.pause();playing=false
    }
    func seek(_ value:Double) {
        guard video?.roomID==nil,value.isFinite else { return }
        seconds=max(0,min(value,duration))
        if showNextPreview { withAnimation(.snappy(duration:0.2)) { showNextPreview=false } }
        player.seek(to:CMTime(seconds:seconds,preferredTimescale:600))
    }
    func setRate(_ value:Float) { rate=value;if player.rate>0 { player.rate=value } }
    func setVolume(_ value:Double) { volume=value;player.volume=Float(value) }
    func persist() { if video?.roomID != nil {return};if preferences?.values.saveHistory == false { return };if let video,cid>0 { library?.save(video:video,cid:cid,seconds:seconds) } }
    func beginAutoNext() {
        guard nextEpisode != nil else { return }
        Task { await playNextEpisode() }
    }
    func cancelAutoNext() {
        autoNextTask?.cancel();autoNextTask=nil;nextCountdown=nil
    }
    func playNextEpisode() async {
        guard let next=nextEpisode,let library=libraryRef else { return }
        cancelAutoNext();withAnimation(.snappy(duration:0.25)) { showNextPreview=false };ended=false
        let target=next.video ?? video
        guard let target else { return }
        await open(video:target,cid:next.cid,library:library,episodes:episodes)
    }
    func stop() {
        persist();generation=UUID();monitor?.cancel();monitor=nil;player.pause();player.replaceCurrentItem(with:nil)
        seconds=0;duration=0;playing=false;loading=false;ended=false;manifest=nil;selectedVideo=nil;selectedAudio=nil
        cancelAutoNext();showNextPreview=false;liveQualities=[];liveQuality=0;liveRoomID=nil;stopLiveChat()
        danmaku=[];subtitles=[];subtitleChoices=[];subtitleID="";episodes=[];episodesLoading=false;videoComments=[];commentsAid=0;commentsOpen=false;videoTint=nil
    }
    func shutdown() async { stop();await gateway.stop() }
    private func loadTimedText(bvid:String,cid:Int,ticket:UUID) async {
        do {
            var request=URLRequest(url:URL(string:"https://comment.bilibili.com/\(cid).xml")!)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15",forHTTPHeaderField:"User-Agent")
            request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
            let (data,response)=try await URLSession.shared.data(for:request)
            guard generation==ticket else { return }
            if (response as? HTTPURLResponse)?.statusCode==200 {
                let parsed=await Task.detached(priority:.utility) { DanmakuParser.parse(data) }.value
                guard generation==ticket else { return };danmaku=parsed
            }
        } catch { if ticket==generation { notice="弹幕暂不可用，视频播放不受影响。" } }
        do {
            let data=try await BiliAPI.shared.subtitleInfo(bvid:bvid,cid:cid)
            guard generation==ticket else { return };subtitleChoices=data["subtitle"]["subtitles"].array
        } catch { /* no subtitle is a valid state */ }
    }
    /// 视频评论区（供播放器悬浮面板使用）。
    func loadComments(video:Video) async {
        var aid=video.aid
        if aid==0,let detail=try? await BiliAPI.shared.detail(video.bvid) { aid=detail["aid"].int }
        guard aid != 0,let data=try? await BiliAPI.shared.comments(aid:aid) else { return }
        commentsAid=aid
        videoComments=data["replies"].array
    }
    func ensureEpisodes() async throws {
        if !episodes.isEmpty {return}
        guard let video,video.roomID==nil else {return}
        let ticket=generation
        if video.isSeason,let seasonID=video.seasonID {
            let data=try await BiliAPI.shared.season(seasonID)
            guard ticket==generation else {throw CancellationError()}
            episodes=data["episodes"].array.enumerated().map {index,item in
                Episode(video:Video.episode(item,seasonID:seasonID,seasonTitle:data["title"].string),cid:item["cid"].int,title:item["show_title"].string.isEmpty ? item["title"].string+" "+item["long_title"].string:item["show_title"].string,page:index+1)
            }
        } else {
            let data=try await BiliAPI.shared.detail(video.bvid)
            guard ticket==generation else {throw CancellationError()};episodes=data["pages"].array.map(Episode.init)
        }
    }
    func chooseSubtitle(_ id:String) async {
        subtitleID=id;subtitles=[];guard !id.isEmpty,let entry=subtitleChoices.first(where:{$0["id"].string==id}) else { return }
        let ticket=generation
        guard let url=URL(string:Video.secure(entry["subtitle_url"].string)),url.scheme=="https",let host=url.host,host=="hdslb.com" || host.hasSuffix(".hdslb.com") else { return }
        do {
            let (data,_)=try await URLSession.shared.data(from:url)
            let json=try JSONDecoder().decode(JSON.self,from:data)
            guard ticket==generation,subtitleID==id else { return }
            subtitles=json["body"].array.enumerated().map { SubtitleCue(id:$0.offset,json:$0.element) }
        } catch { if ticket==generation { notice="字幕加载失败，请重试。" } }
    }
}
// The sole AppKit view is a rendering surface. It contains no controls or event handlers.
struct VideoSurface:NSViewRepresentable {
    let player:AVPlayer
    var onWindow:(NSWindow?)->Void = { _ in }
    final class Surface:NSView {
        var onWindow:(NSWindow?)->Void = { _ in }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow();onWindow(window) }
        let videoLayer=AVPlayerLayer()
        override init(frame:NSRect) { super.init(frame:frame);wantsLayer=true;layer=videoLayer;videoLayer.videoGravity = .resizeAspect;videoLayer.backgroundColor=NSColor.black.cgColor }
        required init?(coder:NSCoder) { nil }
    }
    func makeNSView(context:Context)->Surface { let view=Surface(frame:.zero);view.onWindow=onWindow;view.videoLayer.player=player;return view }
    func updateNSView(_ view:Surface,context:Context) { view.videoLayer.player=player;view.onWindow=onWindow;if view.window != nil { onWindow(view.window) } }
    static func dismantleNSView(_ view:Surface,coordinator:()) { view.videoLayer.player=nil }
}
