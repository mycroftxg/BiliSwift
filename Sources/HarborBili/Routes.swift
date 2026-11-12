import HarborCore

enum AppRoute:Hashable {
    case video(Video),creator(Creator),collection(CreatorCollection),dynamic(DynamicItem)
    var videoID:String? {if case .video(let video)=self {return video.bvid};return nil}
}
