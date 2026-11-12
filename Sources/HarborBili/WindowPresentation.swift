import SwiftUI
import AppKit

/// Window operations only. All visible controls remain SwiftUI views.
@MainActor @Observable final class WindowPresentation {
    var immersive=false { didSet { applyChrome() } }
    var toolbarOverCover=true
    var fullScreen=false
    @ObservationIgnored weak var window:NSWindow?
    func attach(_ window:NSWindow?) {
        guard let window else { return };self.window=window
        let value=window.styleMask.contains(.fullScreen)
        if fullScreen != value { fullScreen=value }
        applyChrome()
    }
    func refresh() { attach(window) }
    func toggleFullScreen() { guard let window else { return };window.toggleFullScreen(nil) }
    func exitFullScreen() { if let window,window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
    func leavePlayback() { exitFullScreen();immersive=false }
    /// 沉浸播放时收起窗口装饰：工具栏、标题与红绿灯一并隐藏，避免与播放器返回按钮冲突；退出播放后恢复。
    private func applyChrome() {
        guard let window else { return }
        window.toolbar?.isVisible = !immersive
        window.titleVisibility = immersive ? .hidden : .visible
        for type in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton] {
            window.standardWindowButton(type)?.isHidden = immersive
        }
    }
}
