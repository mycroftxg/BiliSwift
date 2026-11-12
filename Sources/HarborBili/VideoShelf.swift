import SwiftUI
import HarborCore

/// 横向栏目统一处理：向两侧多露一点、允许越界绘制、背景延伸到侧栏玻璃下。
struct ShelfBleed:ViewModifier {
    var margin:CGFloat=32
    func body(content:Content)->some View {
        content
            .contentMargins(.horizontal,margin,for:.scrollContent)
            .padding(.horizontal,-margin)
            .scrollClipDisabled()
            .backgroundExtensionEffect()
    }
}
extension View { func shelfBleed(_ margin:CGFloat=32)->some View { modifier(ShelfBleed(margin:margin)) } }

struct VideoShelf:View {
    let videos:[Video]
    var cardWidth:CGFloat=270
    var body:some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment:.top,spacing:20) {
                ForEach(videos) {video in NavigationLink(value:AppRoute.video(video)) {VideoCard(video:video).frame(width:cardWidth)}.buttonStyle(.plain)}
            }.scrollTargetLayout()
        }.scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            .shelfBleed(32)
    }
}
struct HeroCarousel:View {
    let videos:[Video]
    let height:CGFloat
    let active:Bool
    let open:(Video)->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppPreferences.self) private var preferences
    @State private var index=0
    @State private var hovered=false
    @State private var captionOffset:CGFloat=0
    @State private var captionOpacity:Double=1
    @State private var captionTask:Task<Void,Never>?
    @State private var captionVideo:Video?
    @State private var switching=false
    private var slides:[Video] {Array(videos.prefix(5))}
    private var current:Video? {slides.isEmpty ? nil:slides[min(index,slides.count-1)]}
    var body:some View {
        GeometryReader { geometry in
            ZStack(alignment:.bottomLeading) {
                if let current {
                    HeroCard(video:current,action:{open(current)},height:height,showsCaption:false)
                        .id(current.id)
                        .transition(.opacity)
                }
                if let caption=captionVideo ?? current {
                    HeroCaption(video:caption,width:geometry.size.width,height:height,action:{open(caption)})
                        .offset(y:captionOffset)
                        .opacity(captionOpacity)
                }
            }
        }.frame(maxWidth:.infinity)
            .frame(height:height)
            .overlay(alignment:.bottomTrailing) {
            if slides.count>1 {
                HStack(spacing:9) {
                    ForEach(Array(slides.enumerated()),id:\.element.id) {position,video in
                        Button {step(to:position)} label:{
                            Capsule().fill(position==index ? .white:.white.opacity(0.4)).frame(width:position==index ? 18:6,height:6)
                                .padding(.vertical,8).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityLabel("推荐第 \(position+1) 页，共 \(slides.count) 页")
                            .accessibilityAddTraits(position==index ? .isSelected:[])
                    }
                }.padding(.horizontal,12).glassEffect(.regular,in:.capsule).environment(\.colorScheme,.dark).padding(.bottom,18).padding(.trailing,40)
            }
            }
            .contentShape(.rect)
            .simultaneousGesture(DragGesture(minimumDistance:25).onEnded {value in
                guard abs(value.translation.width)>abs(value.translation.height) else { return }
                if value.translation.width < -50 {step(by:1)}
                else if value.translation.width > 50 {step(by:-1)}
            })
            .onHover {hovered=$0}
            .task(id:slides.map(\.id).joined(separator:",")) {
                guard !slides.isEmpty else { return }
                // 低电量模式只预取当前一张；正常模式预取全部，切换更顺。
                let candidates=preferences.values.lowPowerMode ? [slides[min(index,slides.count-1)]] : slides
                for video in candidates {
                    guard !Task.isCancelled else { return }
                    await prefetch(video)
                }
            }
            .task(id:"\(active)|\(slides.map(\.id).joined(separator:","))") {
                guard active,slides.count>1,!reduceMotion,!preferences.values.lowPowerMode,!ProcessInfo.processInfo.isLowPowerModeEnabled else{return}
                while !Task.isCancelled {
                    do {try await Task.sleep(for:.seconds(6))}catch{return}
                    guard !Task.isCancelled else{return}
                    if scenePhase == .active,!hovered {step(by:1)}
                }
            }
    }
    private func prefetch(_ video:Video) async {
        if video.isSeason {
            guard let seasonID=video.seasonID,
                  let detail=try? await BiliAPI.shared.season(seasonID),
                  !Task.isCancelled else { return }
            _ = await TMDBPosters.shared.backdrop(for:video,detail:detail,token:preferences.values.tmdbToken)
        } else {
            _ = await RemoteImageStore.shared.image(video.cover,width:1440)
        }
    }
    private func step(by offset:Int) {
        guard slides.count>1 else{return}
        step(to:(min(index,slides.count-1)+offset+slides.count)%slides.count)
    }
    private func step(to position:Int) {
        guard slides.indices.contains(position),position != index else{return}
        guard !reduceMotion else { captionVideo=slides[position];index=position;return }
        if preferences.values.lowPowerMode {
            captionVideo=slides[position];captionOffset=0;captionOpacity=1
            withAnimation(.easeInOut(duration:0.3)) { index=position }
            return
        }
        // 动画期间忽略新的切换，避免两段动画叠加造成上一张"回魂"。
        guard !switching else { return }
        switching=true
        captionTask?.cancel()
        // 先让旧文字上移淡出，再换图并从下方淡入，保证"消失"也有动画。
        withAnimation(.easeIn(duration:0.22)) { captionOpacity=0;captionOffset = -14 }
        let target=position
        captionTask=Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(240))
            guard !Task.isCancelled else { switching=false;return }
            captionVideo=slides[target]
            captionOffset=24;captionOpacity=0
            withAnimation(.easeInOut(duration:0.7)) { index=target }
            withAnimation(.easeOut(duration:0.5)) { captionOffset=0;captionOpacity=1 }
            try? await Task.sleep(for:.milliseconds(780))
            guard !Task.isCancelled else { return }
            switching=false
        }
    }
}

private struct HeroCaptionShift:ViewModifier {
    let y:CGFloat
    let opacity:Double
    func body(content:Content)->some View { content.offset(y:y).opacity(opacity) }
}
extension AnyTransition {
    static var heroCaptionShift:AnyTransition {
        .asymmetric(
            insertion:.modifier(active:HeroCaptionShift(y:26,opacity:0),identity:HeroCaptionShift(y:0,opacity:1)),
            removal:.modifier(active:HeroCaptionShift(y:-16,opacity:0),identity:HeroCaptionShift(y:0,opacity:1))
        )
    }
}
