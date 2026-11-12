import Foundation
import CoreText

public struct ScheduledDanmaku:Identifiable,Sendable {
    public var id:Int { item.id }
    public let item:Danmaku,start:Double,duration:Double,width:Double,lane:Int
    public var end:Double { start+duration }
    public func centerX(viewport:Double,at time:Double)->Double {
        let progress=min(1,max(0,(time-start)/duration))
        if item.mode==4 || item.mode==5 { return viewport/2 }
        if item.mode==6 { return -width/2+(viewport+width)*progress }
        return viewport+width/2-(viewport+width)*progress
    }
}
public struct DanmakuTimeline:Sendable {
    public let items:[ScheduledDanmaku]
    public let maximumDuration:Double
    public init(comments:[Danmaku],viewport:Double,fontSize:Double,density:Int,lanes:Int,speedMultiplier:Double=1) {
        let width=max(1,viewport),laneCount=max(1,lanes),capacity=max(1,density)
        let speed=max(60,width/12)*max(0.5,min(1.5,speedMultiplier))
        var ready=[Double](repeating: -.infinity,count:laneCount)
        var laneEnds=ready,laneModes=[Int](repeating:1,count:laneCount)
        var top=[Double](repeating: -.infinity,count:2),bottom=top
        var activeEnds:[Double]=[],result:[ScheduledDanmaku]=[],maximum=0.0
        let font=CTFontCreateUIFontForLanguage(.emphasizedSystem,CGFloat(fontSize),nil) ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString,CGFloat(fontSize),nil)
        for comment in comments {
            if Task.isCancelled { break }
            activeEnds.removeAll { $0<=comment.time }
            guard activeEnds.count<capacity else { continue }
            let attributed=NSAttributedString(string:comment.text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
            let line=CTLineCreateWithAttributedString(attributed)
            let textWidth=max(1,ceil(CTLineGetTypographicBounds(line,nil,nil,nil))+16)
            let fixed=comment.mode==4 || comment.mode==5
            let duration=fixed ? 5:(width+textWidth)/speed
            let lane:Int
            if comment.mode==4 {
                guard let slot=bottom.indices.filter({bottom[$0]<=comment.time}).min(by:{bottom[$0]<bottom[$1]}) else {continue}
                lane=slot;bottom[slot]=comment.time+duration
            } else if comment.mode==5 {
                guard let slot=top.indices.filter({top[$0]<=comment.time}).min(by:{top[$0]<top[$1]}) else {continue}
                lane=slot;top[slot]=comment.time+duration
            } else {
                let direction=comment.mode==6 ? 6:1
                let available=ready.indices.filter { index in
                    comment.time >= (laneModes[index]==direction ? ready[index]:laneEnds[index])
                }
                guard let slot=available.min(by:{ready[$0]<ready[$1]}) else {continue}
                lane=slot;ready[slot]=comment.time+(textWidth+40)/speed
                laneEnds[slot]=comment.time+duration;laneModes[slot]=direction
            }
            result.append(ScheduledDanmaku(item:comment,start:comment.time,duration:duration,width:textWidth,lane:lane))
            activeEnds.append(comment.time+duration);maximum=max(maximum,duration)
        }
        items=result;maximumDuration=maximum
    }
    public func active(at time:Double)->[ScheduledDanmaku] {
        guard time.isFinite,!items.isEmpty else { return [] }
        func upper(_ value:Double)->Int { var low=0,high=items.count;while low<high {let middle=(low+high)/2;if items[middle].start<=value {low=middle+1}else{high=middle}};return low }
        let start=upper(time-maximumDuration),end=upper(time)
        guard start<end else {return []}
        return items[start..<end].filter { $0.end>time }
    }
}
