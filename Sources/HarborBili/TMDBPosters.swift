import SwiftUI
import HarborCore

/// 按片名和年份查找同一条 TMDB 记录的两种图片。
@MainActor final class TMDBPosters {
    static let shared=TMDBPosters()
    enum Kind:String {
        case movie, tv

        init(seasonType: Int) {
            self = seasonType == 2 || seasonType == 3 ? .movie : .tv
        }
    }
    struct Artwork {
        var poster:String?
        var backdrop:String?
    }
    private var cache:[String:Artwork]=[:]
    private var inflight:[String:Task<Artwork,Never>]=[:]

    static func year(from text: String) -> Int? {
        let value = text.prefix(4)
        guard value.count == 4, let year = Int(value), (1800...2100).contains(year) else { return nil }
        return year
    }

    func poster(title:String,token:String,kind:Kind,year:Int?=nil) async -> String? {
        await artwork(title:title,token:token,kind:kind,year:year).poster
    }

    func artwork(title:String,token:String,kind:Kind,year:Int?=nil) async -> Artwork {
        let value=token.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else { return Artwork() }
        let trimmed=title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Artwork() }
        let normalized=trimmed.replacingOccurrences(of:" ",with:"")
        if year == nil,normalized.count<=3 { return Artwork() }
        let key=value+"|"+kind.rawValue+"|"+trimmed+"|"+(year.map(String.init) ?? "")
        if let hit=cache[key] { return hit }
        if let task=inflight[key] { return await task.value }
        let task=Task<Artwork,Never> {
            await Self.search(title:trimmed,token:value,kind:kind,year:year)
        }
        inflight[key]=task
        let result=await task.value
        inflight[key]=nil
        cache[key]=result
        return result
    }

    func backdrop(for video: Video, detail: JSON, token: String, width: Int = 1920) async -> NSImage? {
        let title = detail["title"].string.isEmpty ? video.title : detail["title"].string
        let kind = Kind(seasonType: detail["type"].int)
        let year = Self.year(from: detail["publish"]["pub_time"].string)
        let artwork = await artwork(title: title, token: token, kind: kind, year: year)
        let fallback = [detail["bkg_cover"].string]
            + detail["episodes"].array.prefix(3).map { $0["cover"].string }
        return await SeasonArtwork.load(preferred: artwork.backdrop, fallback: fallback, width: width, portrait: false)
    }

    private static func search(title:String,token:String,kind:Kind,year:Int?) async -> Artwork {
        for language in ["zh-CN","en-US"] {
            var components=URLComponents(string:"https://api.themoviedb.org/3/search/\(kind.rawValue)")!
            components.queryItems=[.init(name:"query",value:title),.init(name:"language",value:language),.init(name:"include_adult",value:"false"),.init(name:"page",value:"1")]
            guard let url=components.url else { continue }
            var request=URLRequest(url:url)
            request.timeoutInterval=8
            request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            request.setValue("application/json",forHTTPHeaderField:"Accept")
            guard let (data,response)=try? await URLSession.shared.data(for:request),
                  (response as? HTTPURLResponse)?.statusCode==200,
                  let root=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let results=root["results"] as? [[String:Any]] else { continue }
            if let item = matchingTitle(in: results, title: title, year: year) {
                return Artwork(
                    poster: imageURL(item["poster_path"], size: "w780"),
                    backdrop: imageURL(item["backdrop_path"], size: "w1280")
                )
            }
        }
        return Artwork()
    }
    private static func imageURL(_ field: Any?, size: String) -> String? {
        guard let path = field as? String, path.hasPrefix("/") else { return nil }
        return "https://image.tmdb.org/t/p/\(size)" + path
    }

    static func matchingTitle(in results: [[String: Any]], title: String, year: Int?) -> [String: Any]? {
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let target = normalized(title)
        guard !target.isEmpty else { return nil }
        let matching = results.filter { item in
            ["title", "name", "original_title", "original_name"].contains { field in
                guard let name = item[field] as? String else { return false }
                return normalized(name) == target
            }
        }
        guard let year else { return matching.count == 1 ? matching.first : nil }
        let exact = matching.filter { item in
            let date = (item["release_date"] as? String) ?? (item["first_air_date"] as? String) ?? ""
            return Self.year(from: date) == year
        }
        return exact.count == 1 ? exact.first : nil
    }

}

/// 竖版海报卡片（2:3），用于番剧/国创/电影/电视剧/纪录片等 PGC 分区。
struct PosterCard:View {
    let video:Video
    var token:String=""
    var kind:TMDBPosters.Kind = .tv
    @State private var image:NSImage?
    @State private var loading=true
    var body:some View {
        NavigationLink(value:AppRoute.video(video)) {
            VStack(alignment:.leading,spacing:8) {
                Color.clear.aspectRatio(2.0/3.0,contentMode:.fit)
                    .overlay {
                        if let image {
                            SeasonArtwork(image: image)
                        } else {
                            Rectangle().fill(.quaternary).overlay {
                                if loading { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius:12))
                    .overlay(alignment:.bottomTrailing) {
                        if video.roomID == nil,!video.durationLabel.isEmpty {
                            Text(video.durationLabel).font(.caption2.monospacedDigit())
                                .padding(4).background(.black.opacity(0.6),in:.rect(cornerRadius:4))
                                .foregroundStyle(.white).padding(6)
                        }
                    }
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading)
                if !video.author.isEmpty {
                    Text(video.author).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }.buttonStyle(.plain)
        .task(id: video.bvid + "|" + token) {
            let poster = await TMDBPosters.shared.poster(title: video.title, token: token, kind: kind)
            let selected = await SeasonArtwork.load(preferred: poster, fallback: [video.cover], width: 720, portrait: true)
            guard !Task.isCancelled else { return }
            image = selected
            loading = false
        }
    }
}

struct PosterGrid:View {
    let videos:[Video]
    var token:String=""
    var kind:TMDBPosters.Kind = .tv
    private var signature:String { videos.map(\.bvid).joined(separator:",") }
    var body:some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:170,maximum:230),spacing:20)],alignment:.leading,spacing:26) {
            ForEach(videos) { video in
                PosterCard(video:video,token:token,kind:kind)
            }
        }
        .task(id:signature) {
            // 预加载首屏海报，避免卡片先显示官方封面再跳变成 TMDB 海报。
            let batch=Array(videos.prefix(24))
            await withTaskGroup(of:Void.self) { group in
                var iterator=batch.makeIterator()
                func addNext() {
                    guard let video=iterator.next() else { return }
                    group.addTask { _=await TMDBPosters.shared.poster(title:video.title,token:token,kind:kind,year:nil) }
                }
                for _ in 0..<4 { addNext() }
                for await _ in group { addNext() }
            }
        }
    }
}


/// 等比铺满封面区域，裁掉超出边缘的部分。
struct SeasonArtwork: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .accessibilityHidden(true)
    }

    @MainActor static func load(preferred: String?, fallback: [String], width: Int, portrait: Bool) async -> NSImage? {
        var alternate: NSImage?
        for source in [preferred].compactMap({ $0 }) + fallback where !source.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard let image = await RemoteImageStore.shared.image(source, width: width) else { continue }
            let ratio = image.size.width / image.size.height
            if portrait ? ratio < 1 : ratio >= 1.3 { return image }
            if portrait, source != preferred, alternate == nil { alternate = image }
        }
        return alternate
    }
}
