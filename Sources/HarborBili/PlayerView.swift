import SwiftUI
import AppKit
import HarborCore

private enum PlayerPopover:String { case quality,speed,subtitles,episodes,danmaku,info }
struct PlayerPanel:View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppPreferences.self) private var preferences
    @Environment(WindowPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var immersive=false
    var onBack:()->Void = {}
    @State private var scrubbing=false
    @State private var scrub:Double=0
    @State private var controlsVisible=true
    @State private var liveChatVisible=true
    @State private var lastInteraction=Date()
    @State private var popover:PlayerPopover?
    @State private var draft=""
    @State private var sending=false
    @State private var toast:String?
    @State private var toastTask:Task<Void,Never>?
    @State private var fetchingEpisodes=false
    @State private var episodeFailure:String?
    @State private var liking=false
    @State private var liked=false
    @State private var holdingLike=false
    @State private var tripling=false
    @State private var holdProgress:CGFloat=0
    @State private var holdDone=false
    @State private var holdStage=0
    @State private var longPressedAt=Date.distantPast
    @FocusState private var focused:Bool
    var body:some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                VideoSurface(player:controller.player,onWindow:{presentation.attach($0)})
                if controller.showDanmaku {
                    DanmakuOverlay(items:controller.danmaku,seconds:controller.seconds,playing:controller.playing,rate:Double(controller.rate),reduceMotion:reduceMotion,lowPower:preferences.values.lowPowerMode,fontSize:preferences.values.danmakuSize,density:preferences.values.danmakuDensity,speed:preferences.values.danmakuSpeed)
                        .id(controller.cid).opacity(preferences.values.danmakuOpacity).allowsHitTesting(false).accessibilityHidden(true)
                }
                if let next=controller.nextEpisode,controller.showNextPreview {
                    VStack { Spacer()
                        HStack { Spacer()
                            NextEpisodeCard(title:next.title,cover:next.video?.cover ?? "",countdown:controller.nextCountdown) {
                                Task { await controller.playNextEpisode() }
                            }
                        }
                    }.padding(.trailing,24).padding(.bottom,132)
                    .transition(.asymmetric(
                        insertion:.move(edge:.trailing).combined(with:.opacity),
                        removal:.move(edge:.trailing).combined(with:.opacity)
                    ))
                    .animation(.spring(response:0.62,dampingFraction:0.9),value:controller.showNextPreview)
                }
                if controller.video?.roomID != nil,liveChatVisible {
                    HStack { Spacer();LiveChatPanel(messages:controller.liveMessages,status:controller.liveChatStatus) }
                        .padding(.top,88).padding(.trailing,24).padding(.bottom,150)
                        .allowsHitTesting(true)
                        .transition(.asymmetric(
                            insertion:.move(edge:.trailing).combined(with:.opacity),
                            removal:.move(edge:.trailing).combined(with:.opacity)
                        ))
                        .animation(.spring(response:0.55,dampingFraction:0.9),value:liveChatVisible)
                }
                VStack { Spacer();if !controller.subtitle.isEmpty {
                    Text(controller.subtitle).font(.system(size:preferences.values.subtitleSize,weight:.medium))
                        .foregroundStyle(.white).multilineTextAlignment(.center).padding(10)
                        .background(.black.opacity(0.7),in:.rect(cornerRadius:8))
                        .padding(.horizontal,40).padding(.bottom,controlsVisible ? 125:26)
                } }.allowsHitTesting(false)
                if controller.loading,!controlsVisible { ProgressView().controlSize(.large).tint(.white).frame(width:76,height:76).glassEffect(.regular,in:.circle).overlay { Circle().strokeBorder(.white.opacity(0.08),lineWidth:1) } }
                if let error=controller.error {
                    VStack(spacing:14) {
                        Image(systemName:"exclamationmark.triangle").font(.largeTitle)
                        Text("暂时无法播放").font(.title2.bold())
                        Text(error).font(.callout).multilineTextAlignment(.center).frame(maxWidth:420)
                        HStack { Button("返回详情",action:onBack);Button("重新播放") { retry() } }.buttonStyle(.glass)
                    }.foregroundStyle(.white).padding(30).glassEffect(.regular,in:.rect(cornerRadius:24))
                }
                if controlsVisible {
                    controls(size:geometry.size)
                        .foregroundStyle(.white)
                        .transition(reduceMotion ? .identity:.opacity)
                }
            }
            .overlay(alignment:.bottomLeading) {
                if let toast {
                    Text(toast)
                        .font(.system(size:13,weight:.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal,16).padding(.vertical,9)
                        .glassEffect(.regular,in:.capsule)
                        .shadow(color:.black.opacity(0.25),radius:12,y:5)
                        .padding(.leading,32).padding(.bottom,186)
                        .transition(.asymmetric(
                            insertion:.move(edge:.leading).combined(with:.opacity),
                            removal:.move(edge:.leading).combined(with:.opacity)
                        ))
                        .allowsHitTesting(false)
                }
            }
            .environment(\.colorScheme,.dark)
            .animation(.easeInOut(duration:0.2),value:controlsVisible)
            .onChange(of:controller.notice,initial:true) { _, value in
                if let value,!value.isEmpty { showToast(value);Task { @MainActor in controller.notice=nil } }
            }
                .contentShape(.rect)
                .onContinuousHover { phase in if case .active = phase { reveal() } }
                .onHover { inside in if !inside { hideControls() } }
                .simultaneousGesture(TapGesture().onEnded { reveal() })
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.space) { controller.toggle();reveal();return .handled }
                .onKeyPress(.leftArrow) { controller.seek(controller.seconds-10);reveal();return .handled }
                .onKeyPress(.rightArrow) { controller.seek(controller.seconds+10);reveal();return .handled }
                .onExitCommand { if presentation.fullScreen { presentation.exitFullScreen() } else { onBack() } }
        }
        .onDisappear { controller.pause() }
        .onChange(of:scenePhase) { _,phase in if phase == .background { controller.pause() } }
        .modifier(PlayerSizing(immersive:immersive))
            .task {
                if immersive { focused=true }
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.milliseconds(300)) } catch { return }
                    let hide=preferences.values.autoHide && controller.playing && !controller.loading && controller.error==nil && !scrubbing && popover==nil && Date().timeIntervalSince(lastInteraction)>1.0
                    if hide,controlsVisible { hideControls() }
                    if !controller.playing,!controlsVisible { controlsVisible=true }
                }
            }
            .task(id:controller.video?.bvid) {
                liked=false
                if let video=controller.video,video.roomID==nil {
                    do {let value=try await BiliAPI.shared.request("/x/web-interface/archive/has/like",["bvid":video.bvid]);if controller.video?.bvid==video.bvid {liked=value.int==1}} catch {}
                }
            }
            .onChange(of:preferences.values.danmaku) { _,value in controller.showDanmaku=value }
    }
    private func controls(size:CGSize)->some View {
        ZStack {
            VStack { LinearGradient(colors:[.black.opacity(0.3),.clear],startPoint:.top,endPoint:.bottom).frame(height:100);Spacer();LinearGradient(colors:[.clear,.black.opacity(0.72),.black.opacity(0.85)],startPoint:.top,endPoint:.bottom).frame(height:210) }.allowsHitTesting(false)
            VStack(spacing:0) {
                HStack(alignment:.center,spacing:12) {
                    backButton
                    Spacer()
                    if controller.video?.roomID == nil {
                        Button {
                            if Date().timeIntervalSince(longPressedAt)>1.6 { submitLike(triple:false) }
                        } label:{
                            HStack(spacing:14) {
                                Image(systemName:liked ? "hand.thumbsup.fill":"hand.thumbsup")
                                    .contentTransition(.symbolEffect(.replace)).symbolEffect(.bounce,value:liked)
                                if tripling {
                                    Image(systemName:"yensign.circle.fill")
                                        .opacity(holdStage>=1 ? 1:0.22)
                                        .scaleEffect(holdStage>=1 ? 1:0.7)
                                        .symbolEffect(.bounce,value:holdStage>=1)
                                    Image(systemName:"star.fill")
                                        .opacity(holdStage>=2 ? 1:0.22)
                                        .scaleEffect(holdStage>=2 ? 1:0.7)
                                        .symbolEffect(.bounce,value:holdStage>=2)
                                }
                                if holdStage>=3 { Text("三连成功").font(.system(size:12,weight:.semibold)).transition(.opacity.combined(with:.scale)) }
                            }
                            .font(.system(size:16,weight:.medium))
                            .animation(.snappy(duration:0.22),value:holdStage)
                            .foregroundStyle(liked ? Color.pink:Color.white)
                            .frame(width:holdStage>=3 ? 214:(tripling ? 176:36),height:36)
                            .overlay {
                                Capsule().trim(from:0,to:holdProgress).stroke(.white.opacity(0.9),lineWidth:1.5)
                                    .opacity(tripling ? 1:0)
                            }
                            .animation(.snappy(duration:0.25),value:tripling)
                            .animation(.linear(duration:1.6),value:holdProgress)
                        }.buttonStyle(.glass).buttonBorderShape(.capsule).disabled(liking)
                            .help("点赞 · 长按 1.6 秒一键三连").accessibilityLabel("点赞，长按一键三连")
                            .onLongPressGesture(minimumDuration:1.6,maximumDistance:24) {
                                longPressedAt=Date();holdDone=true;holdStage=3;submitLike(triple:true)
                                Task { try? await Task.sleep(for:.seconds(1.1));withAnimation(.snappy(duration:0.25)) { tripling=false;holdProgress=0;holdStage=0 } }
                            } onPressingChanged:{ pressing in
                                if pressing {
                                    holdDone=false;holdStage=0
                                    withAnimation(.snappy(duration:0.25)) { tripling=true }
                                    holdProgress=1
                                    Task { try? await Task.sleep(for:.milliseconds(520));if tripling { holdStage=1 };try? await Task.sleep(for:.milliseconds(520));if tripling { holdStage=2 } }
                                } else if !holdDone {
                                    withAnimation(.snappy(duration:0.25)) { tripling=false;holdProgress=0;holdStage=0 }
                                }
                            }
                    }
                    HStack(spacing:10) {
                        Button { controller.setVolume(controller.volume>0 ? 0:preferences.values.volume) } label:{ Image(systemName:controller.volume==0 ? "speaker.slash.fill":"speaker.wave.2.fill") }.buttonStyle(.plain).accessibilityLabel("静音或恢复音量")
                        Slider(value:Binding(get:{controller.volume},set:{controller.setVolume($0)}),in:0...1).tint(.white).frame(width:100).accessibilityLabel("音量")
                    }
                    .padding(.horizontal,14)
                    .frame(height:36)
                    .glassEffect(.regular,in:.capsule)
                }
                Spacer()
                HStack(spacing:32) {
                    if controller.video?.roomID==nil {roundButton("后退 10 秒",symbol:"gobackward.10",size:52) { controller.seek(controller.seconds-10) }}
                    if controller.ended {
                        Button { controller.replay() } label:{
                            VStack(spacing:4) {
                                Image(systemName:"arrow.counterclockwise").font(.system(size:26,weight:.medium))
                                Text("从头播放").font(.caption.weight(.semibold))
                            }.frame(width:96,height:96)
                        }.buttonStyle(.glass).buttonBorderShape(.circle).help("从头播放").accessibilityLabel("从头播放")
                    } else if controller.loading {
                        ProgressView().controlSize(.large).tint(.white).frame(width:76,height:76).glassEffect(.regular,in:.circle).overlay { Circle().strokeBorder(.white.opacity(0.08),lineWidth:1) }
                    } else {
                        roundButton(controller.playing ? "暂停":"播放",symbol:controller.playing ? "pause.fill":"play.fill",size:76) { controller.toggle() }
                    }
                    if controller.video?.roomID==nil {roundButton("前进 10 秒",symbol:"goforward.10",size:52) { controller.seek(controller.seconds+10) }}
                }
                Spacer()
                VStack(alignment:.leading,spacing:14) {
                    HStack(alignment:.bottom) {
                        VStack(alignment:.leading,spacing:5) {
                            Text(controller.video?.author ?? "").font(.caption).foregroundStyle(.white.opacity(0.7))
                            MarqueeText(text:controller.video?.title ?? "",font:.system(size:immersive ? 23:17,weight:.semibold),height:immersive ? 30:22)
                        }.frame(maxWidth:immersive ? 640:360,alignment:.leading)
                            .shadow(color:.black.opacity(0.9),radius:3,y:1)
                        Spacer(minLength:12)
                        GlassEffectContainer(spacing:8) {
                            HStack(spacing:8) {
                                if controller.nextEpisode != nil {
                                    iconButton("forward.end.fill",label:"播放下一集") { Task { await controller.playNextEpisode() } }
                                }
                                if controller.video?.roomID != nil {
                                    iconButton(liveChatVisible ? "bubble.left.and.bubble.right.fill":"bubble.left.and.bubble.right",label:liveChatVisible ? "隐藏实时评论区":"显示实时评论区") { withAnimation(.snappy(duration:0.25)) { liveChatVisible.toggle() } }
                                    iconButton("arrow.clockwise",label:"重新连接直播") { Task { await controller.retryLive() } }
                                } else {
                                    iconButton("text.bubble.fill",label:controller.commentsOpen ? "隐藏评论":"显示评论") { withAnimation(.snappy(duration:0.3)) { controller.commentsOpen.toggle() } }
                                }
                                popupButton("弹幕",symbol:"text.bubble",panel:.danmaku)
                                if controller.video?.roomID==nil {
                                    popupButton("选集",symbol:"list.bullet",panel:.episodes)
                                    popupButton("字幕",symbol:"captions.bubble",panel:.subtitles)
                                    popupButton("\(controller.rate.formatted())×",symbol:nil,panel:.speed)
                                }
                                popupButton(qualityButtonTitle,symbol:nil,panel:.quality,dolbyOnly:controller.selectedVideo?.label.contains("杜比视界") == true)
                                popupButton("播放信息",symbol:"info.circle",panel:.info)
                                fullScreenButton
                            }
                        }
                    }
                    if controller.video?.roomID != nil {
                        HStack(spacing:10) {
                            Circle().fill(.red).frame(width:6,height:6)
                            Text("直播中").font(.system(size:11,weight:.semibold))
                            Text("已观看 "+time(controller.seconds)).font(.system(size:11)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            if controller.loading { Text("缓冲中…").font(.system(size:11)).foregroundStyle(.white.opacity(0.7)) }
                        }.padding(.horizontal,14).padding(.vertical,8).frame(width:immersive ? 360:300).glassEffect(.regular,in:.capsule)
                    } else {
                        HStack(spacing:10) {
                            Text(time(scrubbing ? scrub:controller.seconds)).font(.system(size:11,weight:.medium)).monospacedDigit().foregroundStyle(.white.opacity(0.75)).frame(minWidth:34).contentTransition(.numericText()).animation(.snappy(duration:0.18),value:time(scrubbing ? scrub:controller.seconds))
                            Slider(value:Binding(get:{scrubbing ? scrub:controller.seconds},set:{scrub=$0}),in:0...max(1,controller.duration),onEditingChanged:{ editing in
                                if editing { scrub=controller.seconds;scrubbing=true } else { controller.seek(scrub);scrubbing=false };reveal()
                            }).tint(.white).controlSize(.small).accessibilityLabel("播放进度")
                            Text("−"+time(max(0,controller.duration-(scrubbing ? scrub:controller.seconds)))).font(.system(size:11,weight:.medium)).monospacedDigit().foregroundStyle(.white.opacity(0.75)).frame(minWidth:40).contentTransition(.numericText(countsDown:true)).animation(.snappy(duration:0.18),value:time(max(0,controller.duration-(scrubbing ? scrub:controller.seconds))))
                        }.padding(.horizontal,14).padding(.vertical,8).glassEffect(.regular,in:.capsule)
                    }
                }
            }
            .padding(immersive ? 24:18)
        }
    }
    private var backButton:some View {
        roundButton(immersive ? "返回视频详情":"停止播放并返回详情",symbol:"chevron.left",size:36,action:onBack)
    }
    private enum ControlMetrics { static let height:CGFloat=30;static let icon:CGFloat=13;static let font:CGFloat=12 }
    private func iconButton(_ symbol:String,label:String,action:@escaping()->Void)->some View {
        Button { reveal();action() } label:{
            Image(systemName:symbol).font(.system(size:ControlMetrics.icon,weight:.semibold))
                .frame(width:36,height:ControlMetrics.height)
        }.buttonStyle(.glass).buttonBorderShape(.capsule).help(label).accessibilityLabel(label)
    }
    private var fullScreenButton:some View {
        Button {
            reveal();if !immersive {presentation.immersive=true};presentation.toggleFullScreen()
        } label:{ Image(systemName:presentation.fullScreen ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")
            .font(.system(size:ControlMetrics.icon,weight:.semibold)).frame(width:36,height:ControlMetrics.height) }
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .help(presentation.fullScreen ? "退出全屏":"全屏播放").accessibilityLabel(presentation.fullScreen ? "退出全屏":"全屏播放")
    }
    private func roundButton(_ title:String,symbol:String,size:CGFloat,action:@escaping()->Void)->some View {
        Button { reveal();action() } label:{ Image(systemName:symbol).font(.system(size:size>60 ? 30: size>45 ? 23:16,weight:.medium)).frame(width:size,height:size) }
            .buttonStyle(.glass).buttonBorderShape(.circle).help(title).accessibilityLabel(title)
    }
    private func popupButton(_ title:String,symbol:String?,panel:PlayerPopover,dolbyOnly:Bool=false)->some View {
        Button {
            reveal()
            if panel == .episodes {
                guard !fetchingEpisodes else {return};fetchingEpisodes=true
                let key=controller.video?.bvid
                Task {
                    defer{fetchingEpisodes=false}
                    do{try await controller.ensureEpisodes();episodeFailure=nil}catch is CancellationError{return}catch{episodeFailure=error.localizedDescription}
                    guard controller.video?.bvid==key else{return};popover=panel
                }
            } else {popover=panel}
        } label:{
            Group {
                if dolbyOnly { DolbyGlyph().frame(width:20,height:12) }
                else if panel == .episodes,fetchingEpisodes { ProgressView().controlSize(.mini) }
                else if let symbol { Image(systemName:symbol).font(.system(size:ControlMetrics.icon,weight:.semibold)) }
                else { Text(title).font(.system(size:ControlMetrics.font,weight:.semibold)).fixedSize(horizontal:true,vertical:false) }
            }
            .frame(minWidth:36,minHeight:ControlMetrics.height)
            .padding(.horizontal,symbol == nil ? 8:0)
            .layoutPriority(symbol == nil ? 1:0)
        }.buttonStyle(.glass).buttonBorderShape(.capsule).help(title).accessibilityLabel(title)
            .popover(isPresented:Binding(get:{popover==panel},set:{if !$0 {popover=nil;reveal()}})) {
                popoverContent(panel).padding(18).frame(width:panel == .info ? 400:panel == .danmaku ? 340:270)
                    .environment(\.colorScheme,preferences.colorScheme ?? .dark)
            }
    }
    @ViewBuilder private func popoverContent(_ panel:PlayerPopover)->some View {
        @Bindable var prefs=preferences
        switch panel {
        case .quality:
            VStack(alignment:.leading,spacing:12) {
                if controller.video?.roomID != nil {
                    Text("直播画质").font(.headline)
                    ForEach(controller.liveQualities) { quality in
                        choice(quality.label,selected:controller.liveQuality==quality.id) { Task { await controller.chooseLiveQuality(quality.id) };popover=nil }
                    }
                    if controller.liveQualities.isEmpty { Text("该直播间暂未返回可选清晰度。").font(.caption).foregroundStyle(.secondary) }
                    Text("直播清晰度取决于主播推流与账号权限；切换会重新连接直播流。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("画质").font(.headline)
                    ForEach(controller.qualityOptions) { track in
                        choice(qualityMenuTitle(track.label),selected:controller.selectedVideo?.quality==track.quality,dolby:track.label.contains("杜比")) { Task { await controller.choose(video:track) };popover=nil }
                            .disabled([125,126].contains(track.quality) && !controller.hdrEligible)
                    }
                    Divider();Text("音轨").font(.headline)
                    ForEach(controller.audioChoices) { track in
                        choice(track.label,selected:controller.selectedAudio?.id==track.id,dolby:track.label.contains("杜比")) { Task { await controller.choose(audio:track) };popover=nil }
                    }
                    Text("高级格式的实际输出请查看播放信息。").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .speed:
            VStack(alignment:.leading,spacing:12) { Text("播放速度").font(.headline);ForEach([Float(0.5),0.75,1,1.25,1.5,2],id:\.self) { value in choice("\(value.formatted())×",selected:controller.rate==value) { controller.setRate(value);popover=nil } } }
        case .subtitles:
            VStack(alignment:.leading,spacing:12) {
                Text("字幕").font(.headline);choice("关闭",selected:controller.subtitleID.isEmpty) { Task { await controller.chooseSubtitle("") };popover=nil }
                ForEach(controller.subtitleChoices.indices,id:\.self) { index in let entry=controller.subtitleChoices[index];choice(entry["lan_doc"].string,selected:controller.subtitleID==entry["id"].string) { Task { await controller.chooseSubtitle(entry["id"].string) };popover=nil } }
                if controller.subtitleChoices.isEmpty { Text("此片源暂无可用字幕").font(.caption).foregroundStyle(.secondary) }
            }
        case .episodes:
            VStack(alignment:.leading,spacing:12) {
                Text("选集").font(.headline)
                ScrollView { VStack(alignment:.leading,spacing:12) { ForEach(controller.episodes) { episode in choice("P\(episode.page)  \(episode.title)",selected:episode.cid==controller.cid) { playEpisode(episode);popover=nil } } } }.frame(height:min(380,max(70,CGFloat(controller.episodes.count)*40)))
                if let episodeFailure { Text(episodeFailure).font(.caption).foregroundStyle(.secondary) }
            }
        case .danmaku:
            VStack(alignment:.leading,spacing:14) {
                Text("弹幕").font(.headline)
                Toggle("显示弹幕",isOn:Binding(get:{controller.showDanmaku},set:{controller.showDanmaku=$0;prefs.values.danmaku=$0}))
                LabeledContent("不透明度") { Slider(value:$prefs.values.danmakuOpacity,in:0.2...1).frame(width:140) }
                TextField("发送一条弹幕",text:$draft).textFieldStyle(.roundedBorder)
                HStack { Spacer();Button("发送") { sendDanmaku() }.buttonStyle(.glassProminent).disabled(sending || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
            }
        case .info: PlaybackInfo()
        }
    }
    private func choice(_ title:String,selected:Bool,dolby:Bool=false,action:@escaping()->Void)->some View {
        Button(action:action) {
            HStack(spacing:10) {
                if dolby { DolbyGlyph().frame(width:18,height:11) }
                Text(title).lineLimit(2)
                Spacer()
                if selected { Image(systemName:"checkmark").foregroundStyle(.tint) }
            }.frame(maxWidth:.infinity,alignment:.leading).contentShape(.rect)
        }.buttonStyle(.plain).font(.callout)
    }
    private var qualityButtonTitle:String {
        if controller.video?.roomID != nil {
            return controller.liveQualities.first { $0.id==controller.liveQuality }?.label ?? "直播画质"
        }
        let raw=controller.selectedVideo?.label ?? "画质"
        if let range=raw.range(of:" 高码率") { return String(raw[..<range.lowerBound])+"+" }
        if let range=raw.range(of:" 60帧") { return String(raw[..<range.lowerBound])+"60" }
        if let range=raw.range(of:" ") { return String(raw[..<range.lowerBound]) }
        return raw
    }
    private func qualityMenuTitle(_ raw:String)->String {
        if let range=raw.range(of:" 高码率") { return String(raw[..<range.lowerBound])+"+（高码率）" }
        return raw
    }
    private func submitLike(triple:Bool) {
        guard !liking,let video=controller.video else {return};liking=true
        Task { defer {liking=false}
            do {
                let response=try await BiliAPI.shared.request(triple ? "/x/web-interface/archive/like/triple":"/x/web-interface/archive/like",["bvid":video.bvid,"like":liked ? "2":"1"],post:true)
                guard controller.video?.bvid==video.bvid else {return}
                if triple {
                    liked=response["like"].bool
                    controller.notice="三连结果：点赞\(response["like"].bool ? "✓":"未完成") · 投币\(response["coin"].bool ? "✓":"未完成") · 收藏\(response["fav"].bool ? "✓":"未完成")"
                } else {liked.toggle();controller.notice=liked ? "已点赞":"已取消点赞"}
            } catch {controller.notice=error.localizedDescription+"；如结果不确定，请先刷新确认，避免重复操作。"}
        }
    }
    private func reveal() {
        lastInteraction=Date()
        controlsVisible=true
    }
    private func showToast(_ text:String) {
        guard !text.isEmpty else { return }
        toastTask?.cancel()
        withAnimation(.spring(response:0.55,dampingFraction:0.88)) { toast=text }
        toastTask=Task { @MainActor in
            try? await Task.sleep(for:.seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration:0.45)) { toast=nil }
        }
    }
    private func hideControls() {
        guard preferences.values.autoHide,controller.playing,popover==nil,!scrubbing else { return }
        withAnimation(reduceMotion ? nil:.easeOut(duration:0.22)) { controlsVisible=false }
        if immersive || presentation.fullScreen {
            // 用系统"隐藏直到鼠标移动"：指针不会在全局卡死，任何移动都会自动恢复。
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
    private func time(_ value:Double)->String { let s=Int(value.isFinite ? max(0,value):0);return s>=3600 ? String(format:"%d:%02d:%02d",s/3600,(s/60)%60,s%60):String(format:"%d:%02d",s/60,s%60) }
    private func retry() { guard let video=controller.video,let library=controller.currentLibrary else { return };let cid=controller.cid,list=controller.episodes;Task { await controller.open(video:video,cid:cid,library:library,episodes:list) } }
    private func playEpisode(_ episode:Episode) {
        guard let current=controller.video,let library=controller.currentLibrary else{return}
        let list=controller.episodes
        Task {await controller.open(video:episode.video ?? current,cid:episode.cid,library:library,episodes:list)}
    }
    private func sendDanmaku() {
        guard !sending, let video = controller.video else { return }
        let submittedDraft = draft
        let text = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= 100 else { showToast("最多 100 字"); return }
        sending = true
        let cid = controller.cid
        let progress = Int(controller.seconds * 1000)
        Task {
            defer { sending = false }
            do {
                if let roomID = video.roomID {
                    try await BiliAPI.shared.sendLiveDanmaku(roomID: roomID, text: text)
                } else {
                    _ = try await BiliAPI.shared.request("/x/v2/dm/post", [
                        "type": "1", "oid": String(cid), "msg": text, "progress": String(progress),
                        "color": "16777215", "fontsize": "25", "pool": "0", "mode": "1",
                        "rnd": String(Int(Date().timeIntervalSince1970 * 1_000_000))
                    ], post: true)
                }
                if draft == submittedDraft { draft = "" }
                showToast("弹幕已发送")
            } catch {
                showToast("发送失败：\(error.localizedDescription)")
            }
        }
    }
}
struct PlaybackInfo:View {
    @Environment(PlaybackController.self) private var p
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("播放状态").font(.title2.bold())
            LabeledContent("系统状态",value:p.outputStatus)
            LabeledContent("观看进度",value:p.syncStatus)
            LabeledContent("视频片源",value:p.selectedVideo?.label ?? "—")
            LabeledContent("视频编码",value:p.selectedVideo?.codec ?? "—")
            LabeledContent("音频片源",value:p.selectedAudio?.label ?? "—")
            LabeledContent("音频编码",value:p.selectedAudio?.codec ?? "—")
            LabeledContent("系统 HDR 能力",value:p.hdrEligible ? "具备播放条件":"未报告可用链路")
            Divider()
            Text("具备 HDR 条件或系统解码成功，不代表已确认当前屏幕的 HDR／杜比视界输出。Hi-Res 与杜比全景声的实际输出也需要设备验证。")
                .font(.caption).foregroundStyle(.secondary)
            Text("高级能力：待真实片源与输出设备验收").font(.caption.bold())
        }.textSelection(.enabled)
    }
}
struct DanmakuOverlay:View {
    let items:[Danmaku],seconds:Double,playing:Bool,rate:Double,reduceMotion:Bool
    var lowPower:Bool=false
    var fontSize:Double=17
    var density:Int=24
    var speed:Double=1
    @State private var sampledAt=Date()
    @State private var schedule:DanmakuTimeline?
    var body:some View {
        GeometryReader { geometry in
            let lineHeight=fontSize+10
            let laneCount=max(1,min(12,Int(max(1,min(geometry.size.height*0.48,geometry.size.height-220))/lineHeight)))
            TimelineView(.animation(minimumInterval:reduceMotion ? 0.5:((lowPower || ProcessInfo.processInfo.isLowPowerModeEnabled) ? 1.0/30.0:1.0/60.0),paused:!playing)) { tick in
                let time=seconds+(playing ? max(0,min(0.4,tick.date.timeIntervalSince(sampledAt)))*rate:0)
                Canvas(rendersAsynchronously:true) { context,size in
                    for entry in schedule?.active(at:time) ?? [] {
                        let color=entry.item.color
                        let text=Text(entry.item.text).font(.system(size:fontSize,weight:.semibold))
                            .foregroundStyle(Color(red:Double((color>>16)&255)/255,green:Double((color>>8)&255)/255,blue:Double(color&255)/255))
                        var layer=context
                        layer.addFilter(.shadow(color:.black.opacity(0.9),radius:1.5,x:0.5,y:1))
                        // 顶部/底部固定弹幕按屏幕中线居中；之前被画成左对齐，视觉上像错位。
                        let y=entry.item.mode==4 ? size.height-135-Double(entry.lane)*lineHeight : entry.item.mode==5 ? 64+Double(entry.lane)*lineHeight:110+Double(entry.lane)*lineHeight
                        layer.draw(layer.resolve(text),at:CGPoint(x:entry.centerX(viewport:size.width,at:time),y:y),anchor:.center)
                    }
                }
            }.clipped()
                .task(id:"\(Int(geometry.size.width))|\(laneCount)|\(fontSize)|\(density)|\(speed)|\(reduceMotion)|\(items.count)") {
                    let comments=reduceMotion ? items.map {Danmaku(id:$0.id,time:$0.time,text:$0.text,mode:$0.mode==4 ? 4:5,color:$0.color)}:items
                    let width=geometry.size.width,size=fontSize,capacity=density,multiplier=speed
                    let build=Task.detached(priority:.userInitiated) {DanmakuTimeline(comments:comments,viewport:width,fontSize:size,density:capacity,lanes:laneCount,speedMultiplier:multiplier)}
                    let timeline=await withTaskCancellationHandler(operation:{await build.value},onCancel:{build.cancel()})
                    guard !Task.isCancelled else {return};schedule=timeline
                }
        }.clipped().onChange(of:seconds) {_,_ in sampledAt=Date()}
    }
}

private struct PlayerSizing:ViewModifier {
    let immersive:Bool
    @ViewBuilder func body(content:Content)->some View {
        if immersive { content.frame(maxWidth:.infinity,maxHeight:.infinity) }
        else { content.aspectRatio(16/9,contentMode:.fit) }
    }
}

struct LiveChatPanel:View {
    let messages:[PlaybackController.LiveMessage]
    let status:String
    var body:some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:7) {
                    ForEach(messages) { message in
                        HStack(alignment:.top,spacing:6) {
                            Text(message.user.isEmpty ? "观众":message.user+":")
                                .font(.caption.weight(.semibold)).foregroundStyle(.cyan).lineLimit(1)
                            Text(message.text).font(.caption).foregroundStyle(.white.opacity(0.92)).fixedSize(horizontal:false,vertical:true)
                        }.frame(maxWidth:.infinity,alignment:.leading).id(message.id)
                    }
                    if messages.isEmpty { Text(status).font(.caption).foregroundStyle(.white.opacity(0.6)) }
                }.padding(14)
            }
            .frame(width:280)
            .frame(maxHeight:340)
            .glassEffect(.regular,in:.rect(cornerRadius:16))
            .onChange(of:messages.last?.id) { _,_ in
                if let last=messages.last { withAnimation(.easeOut(duration:0.2)) { proxy.scrollTo(last.id,anchor:.bottom) } }
            }
        }
    }
}

struct CommentSidebar:View {
    let aid:Int
    var bvid:String=""
    var tint:Color?
    let comments:[JSON]
    var onClose:()->Void
    @State private var store=CommentStore()
    private var items:[JSON] { store.comments.isEmpty ? comments:store.comments }
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Text("评论").font(.title3.bold()).foregroundStyle(.white)
                Text("\(items.count)").font(.callout).foregroundStyle(.white.opacity(0.6)).contentTransition(.numericText()).animation(.snappy,value:items.count)
                Spacer()
                Button { onClose() } label:{ Image(systemName:"xmark").font(.system(size:13,weight:.semibold)).frame(width:30,height:30) }
                    .buttonStyle(.glass).buttonBorderShape(.circle).help("收起评论").accessibilityLabel("收起评论")
            }.padding(.horizontal,16).padding(.vertical,14)
            Divider().opacity(0.25)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    ForEach(Array(items.enumerated()),id:\.offset) { _,comment in
                        PlayerCommentRow(comment:comment,replies:store.replies[comment["rpid"].int] ?? [],loading:store.loadingReplies.contains(comment["rpid"].int)) { root in
                            Task { await store.loadReplies(root:root) }
                        }
                        .onAppear { if comment["rpid"].int == items.last?["rpid"].int { Task { await store.loadMore() } } }
                    }
                    if store.loading { ProgressView().controlSize(.small).frame(maxWidth:.infinity).padding(.vertical,8) }
                    if !store.hasMore,!items.isEmpty { Text("没有更多评论了").font(.caption).foregroundStyle(.white.opacity(0.6)).frame(maxWidth:.infinity).padding(.vertical,10) }
                    if items.isEmpty { Text("正在加载评论…").font(.callout).foregroundStyle(.white.opacity(0.6)) }
                }.padding(16)
            }
        }
        .padding(.vertical,10).padding(.trailing,10)
        .background {
            if let tint {
                RadialGradient(colors:[tint.opacity(0.55),tint.opacity(0.12),.clear],center:.topTrailing,startRadius:8,endRadius:340)
                    .blur(radius:34)
            }
        }
        .glassEffect(.regular.tint((tint ?? .black).opacity(tint == nil ? 0.35:0.16)),in:.rect(cornerRadius:18))
        .clipShape(.rect(cornerRadius:18))
        .environment(\.colorScheme,.dark)
        .task(id:"\(aid)-\(bvid)") { await store.start(aid:aid,bvid:bvid) }
    }
}

struct PlayerCommentRow:View {
    let comment:JSON
    let replies:[JSON]
    let loading:Bool
    let onExpand:(Int)->Void
    private var rpid:Int { comment["rpid"].int }
    private var rcount:Int { comment["rcount"].int }
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(alignment:.top,spacing:10) {
                CoverImage(source:comment["member"]["avatar"].string,width:96,showsPlaceholderIcon:false)
                    .frame(width:34,height:34).clipShape(.circle).clipped()
                VStack(alignment:.leading,spacing:5) {
                    Text(comment["member"]["uname"].string.isEmpty ? "用户":comment["member"]["uname"].string)
                        .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                    Text(comment["content"]["message"].string).font(.callout).foregroundStyle(.white).fixedSize(horizontal:false,vertical:true)
                    HStack(spacing:14) {
                        if comment["like"].int>0 { Label("\(comment["like"].int)",systemImage:"hand.thumbsup") }
                        if rcount>0 { Label("\(rcount)",systemImage:"bubble.right") }
                    }.font(.caption2).foregroundStyle(.white.opacity(0.55))
                }
            }
            if !replies.isEmpty {
                VStack(alignment:.leading,spacing:10) {
                    ForEach(Array(replies.enumerated()),id:\.offset) { _,reply in
                        HStack(alignment:.top,spacing:8) {
                            CoverImage(source:reply["member"]["avatar"].string,width:64,showsPlaceholderIcon:false)
                                .frame(width:24,height:24).clipShape(.circle).clipped()
                            VStack(alignment:.leading,spacing:3) {
                                Text(reply["member"]["uname"].string).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.55))
                                Text(reply["content"]["message"].string).font(.caption).foregroundStyle(.white).fixedSize(horizontal:false,vertical:true)
                            }
                        }.padding(.leading,44)
                    }
                }
            } else if rcount>0 {
                Button(loading ? "加载回复…":"展开 \(rcount) 条回复") { onExpand(rpid) }
                    .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.cyan).padding(.leading,44)
                    .disabled(loading)
            }
        }
    }
}

private struct MarqueeWidthKey:PreferenceKey { static let defaultValue:CGFloat=0;static func reduce(value:inout CGFloat,nextValue:()->CGFloat){value=max(value,nextValue())} }

/// 标题过长时水平循环滚动，短标题保持静止。
struct MarqueeText:View {
    let text:String
    var font:Font = .body
    var height:CGFloat=22
    @State private var textWidth:CGFloat=0
    @State private var animate=false
    var body:some View {
        GeometryReader { geo in
            let over=textWidth>geo.size.width+1
            HStack(spacing:28) {
                Text(text).font(font).fixedSize()
                    .background { GeometryReader { proxy in Color.clear.preference(key:MarqueeWidthKey.self,value:proxy.size.width) } }
                if over { Text(text).font(font).fixedSize() }
            }
            .offset(x:animate ? -(textWidth+28):0)
            .animation(over ? .linear(duration:max(8,Double(textWidth)/45)).repeatForever(autoreverses:false):.default,value:animate)
            .onPreferenceChange(MarqueeWidthKey.self) { textWidth=$0 }
            .onAppear { animate=over }
            .onChange(of:over) { _,value in animate=value }
            .onChange(of:text) { _,_ in animate=false;DispatchQueue.main.async { animate=over } }
        }
        .frame(height:height)
        .clipped()

    }
}

struct NextEpisodeCard:View {
    let title:String
    let cover:String
    let countdown:Int?
    var action:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            Text("下一集").font(.system(size:11,weight:.semibold)).foregroundStyle(.white.opacity(0.65))
            if !cover.isEmpty {
                Thumbnail(source:cover).frame(width:228,height:128).clipShape(.rect(cornerRadius:10))
            }
            Text(title).font(.system(size:13,weight:.semibold)).foregroundStyle(.white).lineLimit(2)
            HStack(spacing:10) {
                if let countdown {
                    Text("\(countdown) 秒后自动播放").font(.system(size:11)).foregroundStyle(.white.opacity(0.7))
                        .contentTransition(.numericText()).animation(.snappy(duration:0.2),value:countdown)
                }
                Spacer()
                Button("立即播放") { action() }.buttonStyle(.glassProminent).controlSize(.small)
            }
        }
        .padding(12)
        .frame(width:252,alignment:.leading)
        .glassEffect(.regular.tint(.black.opacity(0.3)),in:.rect(cornerRadius:14))
        .environment(\.colorScheme,.dark)
    }
}

/// 简易 Dolby 双 D 标志（不使用官方图形资源，避免浅色玻璃下发虚）。
struct DolbyGlyph:View {
    var body:some View {
        HStack(spacing:1) {
            DolbyD().fill(.white)
            DolbyD().fill(.white).scaleEffect(x:-1,y:1)
        }
        .accessibilityLabel("杜比")
    }
}
private struct DolbyD:Shape {
    func path(in rect:CGRect)->Path {
        var path=Path()
        let radius=rect.height/2
        let straight=rect.width-radius
        path.move(to:CGPoint(x:rect.minX,y:rect.minY))
        path.addLine(to:CGPoint(x:rect.minX+straight,y:rect.minY))
        path.addArc(center:CGPoint(x:rect.minX+straight,y:rect.minY+radius),radius:radius,startAngle:.degrees(-90),endAngle:.degrees(90),clockwise:false)
        path.addLine(to:CGPoint(x:rect.minX,y:rect.maxY))
        path.closeSubpath()
        return path
    }
}
