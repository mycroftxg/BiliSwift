import SwiftUI
import HarborCore

struct LiveDetailView:View {
    let video:Video
    @Environment(PlaybackController.self) private var playback
    @Environment(LocalLibrary.self) private var library
    @Environment(WindowPresentation.self) private var presentation
    @Environment(\.dismiss) private var dismiss
    @State private var detail:JSON = .null
    @State private var failure:String?
    @State private var viewport=CGSize(width:1000,height:800)
    private var heroHeight:CGFloat { viewport.width * 9 / 16 }
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                HeroCard(video:video,action:{play()},height:heroHeight)
                VStack(alignment:.leading,spacing:22) {
                    NavigationLink(value:AppRoute.creator(Creator(mid:video.mid,name:video.author))) {Label(video.author,systemImage:"person.crop.circle")}.buttonStyle(.glass)
                    Text(detail["description"].string.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)).font(.body).lineSpacing(5).textSelection(.enabled)
                    LabeledContent("直播分区",value:detail["parent_area_name"].string+" · "+detail["area_name"].string)
                    LabeledContent("房间号",value:String(video.roomID ?? 0))
                    if let failure {Text(failure).foregroundStyle(.red)}
                    Text("播放直播时可查看实时聊天和弹幕。").font(.caption).foregroundStyle(.secondary)
                }.padding(32)
            }
        }.onGeometryChange(for:CGSize.self) { $0.size } action:{ viewport=$0 }
        .ignoresSafeArea(edges:.top).navigationTitle(presentation.immersive || presentation.toolbarOverCover ? "":video.title).navigationBarBackButtonHidden(true)
            .toolbar {ToolbarItem(placement:.navigation) {if !presentation.immersive {Button {dismiss()} label:{Image(systemName:"chevron.left")}}}}
            .task {presentation.toolbarOverCover=true;do{detail=try await BiliAPI.shared.liveRoom(video.roomID ?? 0)}catch{failure=error.localizedDescription}}
    }
    private func play() {presentation.immersive=true;Task {await playback.open(video:video,cid:0,library:library)}}
}
