import SwiftUI

/// 滚动到底部时自动加载下一页，替代"加载更多"按钮，避免被底部播放条遮挡。
struct AutoLoadFooter:View {
    let hasMore:Bool
    let loading:Bool
    let action:() async -> Void

    var body:some View {
        Group {
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth:.infinity).padding(.vertical,12)
            } else if hasMore {
                Color.clear
                    .frame(height:1)
                    .frame(maxWidth:.infinity)
                    .onAppear { Task { await action() } }
            }
        }
    }
}
