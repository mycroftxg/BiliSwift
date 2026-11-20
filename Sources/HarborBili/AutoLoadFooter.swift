import SwiftUI

/// 滚动到底部时自动加载下一页，替代"加载更多"按钮，避免被底部播放条遮挡。
struct AutoLoadFooter:View {
    let hasMore:Bool
    let loading:Bool
    let action:() async -> Void
    @State private var lastFire=Date.distantPast

    var body:some View {
        Group {
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth:.infinity).padding(.vertical,12)
            } else if hasMore {
                Color.clear
                    .frame(height:2)
                    .frame(maxWidth:.infinity)
                    .onScrollVisibilityChange(threshold:0.5) { visible in
                        guard visible,!loading,Date().timeIntervalSince(lastFire)>1.2 else { return }
                        lastFire=Date()
                        Task { await action() }
                    }
            }
        }
    }
}
