import Foundation

public struct MediaSegment: Equatable, Sendable {
    public let span: ByteSpan, duration: Double
    public init(span: ByteSpan, duration: Double) { self.span = span; self.duration = duration }
}
public enum SegmentIndex {
    /// Parse ISO BMFF sidx. The input is the exact index range; offsets are absolute in the source file.
    public static func parse(_ data: Data, absoluteOffset: UInt64) throws -> [MediaSegment] {
        let bytes = Array(data)
        func uint(_ p: Int, _ n: Int) throws -> UInt64 {
            guard p >= 0, n > 0, p <= bytes.count - n else { throw BiliError.invalid("媒体索引不完整") }
            return bytes[p..<(p+n)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        var cursor = 0
        while cursor + 8 <= bytes.count {
            let shortSize = try uint(cursor, 4)
            let extended = shortSize == 1
            let size = extended ? try uint(cursor+8, 8) : shortSize
            let header = extended ? 16 : 8
            guard size >= UInt64(header), size <= UInt64(bytes.count - cursor) else { throw BiliError.invalid("媒体索引 box 越界") }
            let end = cursor + Int(size)
            if String(bytes: bytes[(cursor+4)..<(cursor+8)], encoding: .ascii) != "sidx" { cursor = end; continue }
            var p = cursor + header
            let version = try uint(p, 1); p += 4
            guard version <= 1 else { throw BiliError.invalid("不支持的 sidx 版本") }
            p += 4
            let scale = try uint(p, 4); p += 4
            guard scale > 0 else { throw BiliError.invalid("媒体时间基准无效") }
            let width = version == 0 ? 4 : 8
            p += width // earliest_presentation_time
            let first = try uint(p, width); p += width
            p += 2
            let count = try uint(p, 2); p += 2
            guard count > 0, count <= 10000, p + Int(count) * 12 <= end else { throw BiliError.invalid("媒体分段索引无效") }
            let (base, overflow1) = absoluteOffset.addingReportingOverflow(UInt64(end))
            let (start, overflow2) = base.addingReportingOverflow(first)
            guard !overflow1, !overflow2 else { throw BiliError.invalid("媒体偏移溢出") }
            var offset = start
            var segments: [MediaSegment] = []
            for _ in 0..<Int(count) {
                let reference = try uint(p, 4); p += 4
                guard reference & 0x80000000 == 0 else { throw BiliError.invalid("暂不支持嵌套媒体索引") }
                let length = reference & 0x7fffffff
                let duration = try uint(p, 4); p += 8
                guard length > 0, duration > 0 else { throw BiliError.invalid("空媒体分段") }
                segments.append(MediaSegment(span: ByteSpan(offset:offset,length:length),duration:Double(duration)/Double(scale)))
                let (next, overflow) = offset.addingReportingOverflow(length)
                guard !overflow else { throw BiliError.invalid("媒体偏移溢出") }; offset = next
            }
            return segments
        }
        throw BiliError.invalid("片源没有可用的 sidx 索引")
    }
    public static func playlist(track: MediaTrack, segments: [MediaSegment], resource: String) -> String {
        let target = Int(ceil(segments.map(\.duration).max() ?? 1))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-MAP:URI=\"\(resource)\",BYTERANGE=\"\(track.initialization.length)@\(track.initialization.offset)\""]
        for segment in segments {
            lines += [String(format:"#EXTINF:%.6f,",locale:Locale(identifier:"en_US_POSIX"),segment.duration), "#EXT-X-BYTERANGE:\(segment.span.length)@\(segment.span.offset)",resource]
        }
        lines.append("#EXT-X-ENDLIST"); return lines.joined(separator:"\n") + "\n"
    }
}
