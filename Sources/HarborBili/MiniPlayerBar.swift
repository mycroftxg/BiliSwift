import SwiftUI
import HarborCore

/// Apple Music 风格的后台播放条：收起播放器后仍保留音频，并可随时展开。
struct MiniPlayerBar:View {
    @Environment(PlaybackController.self) private var playback
    @Environment(WindowPresentation.self) private var presentation
    @State private var scrub:Double?

    var body:some View {
        if let video=playback.video {
            HStack(spacing:14) {
                Button(action:restore) {
                    CoverImage(source:video.cover,width:160,showsPlaceholderIcon:false)
                        .frame(width:46,height:46)
                        .clipShape(.rect(cornerRadius:8))
                        .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(.white.opacity(0.12),lineWidth:1) }
                }.buttonStyle(.plain).help("展开播放器")

                VStack(alignment:.leading,spacing:4) {
                    HStack(spacing:8) {
                        Button(action:restore) {
                            Text(video.title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                                .foregroundStyle(.white)
                        }.buttonStyle(.plain).help(video.title)
                        if video.roomID != nil {
                            Text("直播").font(.system(size:9,weight:.bold)).foregroundStyle(.white)
                                .padding(.horizontal,5).padding(.vertical,1)
                                .background(.red.opacity(0.85),in:.capsule)
                        }
                        Spacer(minLength:8)
                        if video.roomID == nil {
                            Text(time(scrub ?? playback.seconds)).font(.system(size:10)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Text(subtitle(video)).font(.system(size:11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                    if video.roomID == nil {
                        Slider(value:Binding(get:{scrub ?? playback.seconds},set:{scrub=$0}),in:0...max(1,playback.duration),onEditingChanged:{ editing in
                            if editing { scrub=playback.seconds }
                            else { if let value=scrub { playback.seek(value) };scrub=nil }
                        })
                        .controlSize(.mini).tint(.white)
                        .accessibilityLabel("播放进度")
                    } else {
                        Capsule().fill(.white.opacity(0.15)).frame(height:3)
                    }
                }

                HStack(spacing:10) {
                    Button { Task { await playback.playPreviousEpisode() } } label:{
                        Image(systemName:"backward.fill").font(.system(size:13))
                    }.buttonStyle(.plain).disabled(video.roomID != nil || (playback.currentEpisodeIndex ?? 0) == 0)
                        .help("上一集")

                    Button { playback.toggle() } label:{
                        Image(systemName:playback.playing ? "pause.fill":"play.fill")
                            .font(.system(size:19))
                            .frame(width:30,height:30)
                            .contentTransition(.symbolEffect(.replace))
                    }.buttonStyle(.plain).help(playback.playing ? "暂停":"播放")

                    Button { Task { await playback.playNextEpisode() } } label:{
                        Image(systemName:"forward.fill").font(.system(size:13))
                    }.buttonStyle(.plain).disabled(playback.nextEpisode == nil).help("下一集")
                }.foregroundStyle(.white)

                HStack(spacing:6) {
                    Image(systemName:playback.volume==0 ? "speaker.slash.fill":"speaker.wave.2.fill")
                        .font(.system(size:11)).foregroundStyle(.white.opacity(0.65))
                    Slider(value:Binding(get:{playback.volume},set:{playback.setVolume($0)}),in:0...1)
                        .frame(width:64).controlSize(.mini).tint(.white)
                        .accessibilityLabel("音量")
                }

                Button(action:restore) { Image(systemName:"chevron.up").font(.system(size:12,weight:.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.75)).help("展开播放器")

                Button { playback.stop() } label:{ Image(systemName:"xmark").font(.system(size:12,weight:.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.55)).help("停止播放并关闭")
            }
            .foregroundStyle(.white)
            .padding(.horizontal,14).padding(.vertical,10)
            .glassEffect(.regular.tint(.black.opacity(0.3)),in:.rect(cornerRadius:16))
            .contentShape(.rect(cornerRadius:16))
            .shadow(color:.black.opacity(0.28),radius:18,y:8)
            .environment(\.colorScheme,.dark)
            .zIndex(20)
            .accessibilityElement(children:.contain)
        }
    }

    private func restore() {
        playback.minimized=false
        withAnimation(.spring(response:0.5,dampingFraction:0.88)) { presentation.immersive=true }
    }
    private func subtitle(_ video:Video)->String {
        if video.roomID != nil { return video.author }
        if let index=playback.currentEpisodeIndex,playback.episodes.count>1 {
            return "第 \(index+1) 集 · \(video.author)"
        }
        return video.author
    }
    private func time(_ value:Double)->String {
        let s=Int(value.isFinite ? max(0,value):0)
        return s>=3600 ? String(format:"%d:%02d:%02d",s/3600,(s/60)%60,s%60) : String(format:"%d:%02d",s/60,s%60)
    }
}
