import SwiftUI
import HarborCore

struct PreferenceValues:Codable,Equatable {
    var appearance="system"
    var quality="balanced"
    var preferredFormat="auto"
    var codec="auto"
    var volume=0.8
    var rate=1.0
    var resume=true
    var autoPlay=false
    var autoHide=true
    var lowPowerMode=false
    var updateSource="auto"
    var hideDelay=3.0
    var danmaku=true
    var danmakuOpacity=0.85
    var danmakuSize=17.0
    var danmakuSpeed=1.0
    var danmakuDensity=24
    var subtitleSize=20.0
    var syncHistory=true
    var saveHistory=true
    var channelIDs=BiliChannel.defaultIDs
    var tmdbToken=""
    init() {}
    enum CodingKeys:String,CodingKey {case appearance,quality,preferredFormat,codec,volume,rate,resume,autoPlay,autoHide,lowPowerMode,hideDelay,updateSource,danmaku,danmakuOpacity,danmakuSize,danmakuSpeed,danmakuDensity,subtitleSize,syncHistory,saveHistory,channelIDs,tmdbToken}
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        appearance=try c.decodeIfPresent(String.self,forKey:.appearance) ?? "system"
        quality=try c.decodeIfPresent(String.self,forKey:.quality) ?? "balanced"
        preferredFormat=try c.decodeIfPresent(String.self,forKey:.preferredFormat) ?? "auto"
        codec=try c.decodeIfPresent(String.self,forKey:.codec) ?? "auto"
        volume=try c.decodeIfPresent(Double.self,forKey:.volume) ?? 0.8
        rate=try c.decodeIfPresent(Double.self,forKey:.rate) ?? 1.0
        resume=try c.decodeIfPresent(Bool.self,forKey:.resume) ?? true
        autoPlay=try c.decodeIfPresent(Bool.self,forKey:.autoPlay) ?? false
        autoHide=try c.decodeIfPresent(Bool.self,forKey:.autoHide) ?? true
        lowPowerMode=try c.decodeIfPresent(Bool.self,forKey:.lowPowerMode) ?? false
        updateSource=try c.decodeIfPresent(String.self,forKey:.updateSource) ?? "auto"
        hideDelay=try c.decodeIfPresent(Double.self,forKey:.hideDelay) ?? 3.0
        danmaku=try c.decodeIfPresent(Bool.self,forKey:.danmaku) ?? true
        danmakuOpacity=try c.decodeIfPresent(Double.self,forKey:.danmakuOpacity) ?? 0.85
        danmakuSize=try c.decodeIfPresent(Double.self,forKey:.danmakuSize) ?? 17.0
        danmakuSpeed=try c.decodeIfPresent(Double.self,forKey:.danmakuSpeed) ?? 1.0
        danmakuDensity=try c.decodeIfPresent(Int.self,forKey:.danmakuDensity) ?? 24
        subtitleSize=try c.decodeIfPresent(Double.self,forKey:.subtitleSize) ?? 20.0
        syncHistory=try c.decodeIfPresent(Bool.self,forKey:.syncHistory) ?? true
        saveHistory=try c.decodeIfPresent(Bool.self,forKey:.saveHistory) ?? true
        channelIDs=try c.decodeIfPresent([String].self,forKey:.channelIDs) ?? BiliChannel.defaultIDs
        tmdbToken=try c.decodeIfPresent(String.self,forKey:.tmdbToken) ?? ""
    }

}
@MainActor @Observable final class AppPreferences {
    var values:PreferenceValues { didSet { save() } }
    private let defaults:UserDefaults
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"preferences.v1"),let saved=try? JSONDecoder().decode(PreferenceValues.self,from:data) { values=saved }
        else { values=PreferenceValues() }
    }
    var colorScheme:ColorScheme? { values.appearance=="dark" ? .dark : values.appearance=="light" ? .light:nil }
    var channels:[BiliChannel] { values.channelIDs.compactMap(BiliChannel.find) }
    func reset() { values=PreferenceValues() }
    func toggleChannel(_ id:String,_ visible:Bool) {
        guard BiliChannel.find(id) != nil else { return }
        var ids=values.channelIDs.filter { $0 != id }
        if visible { ids.append(id) };values.channelIDs=ids
    }
    func moveChannel(_ id:String,by offset:Int) {
        guard let index=values.channelIDs.firstIndex(of:id) else { return }
        let target=index+offset
        guard values.channelIDs.indices.contains(target) else { return }
        values.channelIDs.swapAt(index,target)
    }
    private func save() { if let data=try? JSONEncoder().encode(values) { defaults.set(data,forKey:"preferences.v1") } }
}
