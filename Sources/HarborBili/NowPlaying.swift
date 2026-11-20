import Foundation
import AppKit
import MediaPlayer
import HarborCore

/// 把播放状态注册到 macOS「正在播放」：控制中心、菜单栏媒体面板、媒体键与耳机按键。
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var controller: PlaybackController?
    private var commandsReady = false
    private var artwork: MPMediaItemArtwork?
    private var artworkKey = ""
    private var lastPush = Date.distantPast

    func attach(_ controller: PlaybackController) {
        self.controller = controller
        guard !commandsReady else { return }
        commandsReady = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.resumeFromRemote() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.toggle() }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let controller = self?.controller, controller.nextEpisode != nil else { return }
                await controller.playNextEpisode()
            }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.controller?.seek(0) }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.controller?.seek(event.positionTime) }
            return .success
        }
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let controller = self?.controller else { return }
                controller.seek(controller.seconds + 10)
            }
            return .success
        }
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let controller = self?.controller else { return }
                controller.seek(controller.seconds - 10)
            }
            return .success
        }
    }

    /// 播放器状态变化时调用；默认节流 1 秒，强制刷新用于播放/暂停/切集。
    func update(from controller: PlaybackController, force: Bool = false) {
        guard let video = controller.video else { clear(); return }
        if !force, Date().timeIntervalSince(lastPush) < 1 { return }
        lastPush = Date()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.author,
            MPMediaItemPropertyAlbumTitle: "BiliSwift",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: controller.playing ? Double(controller.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(controller.rate),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.seconds
        ]
        if controller.duration > 0, video.roomID == nil {
            info[MPMediaItemPropertyPlaybackDuration] = controller.duration
        }
        if video.roomID != nil {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = controller.playing ? .playing : .paused

        if artworkKey != video.cover {
            artworkKey = video.cover
            artwork = nil
            Task { @MainActor [weak self] in
                guard let self, let image = await RemoteImageStore.shared.image(video.cover, width: 600) else { return }
                guard self.artworkKey == video.cover else { return }
                let data = image.tiffRepresentation
                let size = image.size
                self.artwork = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                    if let data, let decoded = NSImage(data: data) { return decoded }
                    return NSImage(size: size)
                }
                self.update(from: controller, force: true)
            }
        }
    }

    func clear() {
        lastPush = .distantPast
        artwork = nil
        artworkKey = ""
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
