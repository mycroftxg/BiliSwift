import SwiftUI

/// 距底部还有一段距离时自动加载下一页；用负 bottom padding 让 520pt 触发区不占布局。
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
                    .frame(height:520)
                    .padding(.bottom,-518)
                    .onScrollVisibilityChange(threshold:0.05) { visible in
                        guard visible,!loading,Date().timeIntervalSince(lastFire)>1.2 else { return }
                        lastFire=Date()
                        Task { await action() }
                    }
            }
        }
    }
}
