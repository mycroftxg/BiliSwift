import SwiftUI
import HarborCore
import CryptoKit

/// 按片名和年份查找同一条 TMDB 记录的两种图片。
@MainActor final class TMDBPosters {
    static let shared=TMDBPosters()
    enum Kind:String {
        case movie, tv

        init(seasonType: Int) {
            self = seasonType == 2 || seasonType == 3 ? .movie : .tv
        }
    }
    struct Artwork: Codable, Sendable {
        var poster:String?
        var backdrop:String?
    }
    private struct Cached: Codable {
        let artwork: Artwork
        let expires: Date
    }
    private static let cacheURL = URL.cachesDirectory.appending(path: "BiliSwift/tmdb-artwork.json")
    private var cache: [String: Cached] = {
        guard let data = try? Data(contentsOf: cacheURL),
              let entries = try? JSONDecoder().decode([String: Cached].self, from: data) else { return [:] }
        return entries.filter { $0.value.expires > .now }
    }()

    private var inflight:[String:Task<Artwork,Never>]=[:]

    private var generation = UUID()

    func retryUnmatched() {
        cache = cache.filter { $0.value.artwork.poster != nil || $0.value.artwork.backdrop != nil }
        generation = UUID()
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
    }

    func clearCache() throws {
        retryUnmatched()
        cache.removeAll()
        pendingSave?.cancel()
        pendingSave = nil
        if FileManager.default.fileExists(atPath: Self.cacheURL.path) {
            try FileManager.default.removeItem(at: Self.cacheURL)
        }
    }

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
        let fingerprint = SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let key = "\(fingerprint)|\(kind.rawValue)|\(trimmed)|\(year ?? 0)"
        if let hit = cache[key], hit.expires > .now { return hit.artwork }
        if let task=inflight[key] { return await task.value }
        let ticket = generation
        let task=Task<Artwork,Never> {
            let result = await Self.search(title: trimmed, token: value, kind: kind, year: year)
            guard self.generation == ticket, !Task.isCancelled else { return Artwork() }
            if let result {
                let found = result.poster != nil || result.backdrop != nil
                self.cache[key] = Cached(artwork: result, expires: Date().addingTimeInterval(found ? 604800 : 1800))
                if self.cache.count > 600 {
                    self.cache = Dictionary(uniqueKeysWithValues: self.cache.sorted { $0.value.expires > $1.value.expires }.prefix(500).map { ($0.key, $0.value) })
                }
                if found { self.saveCache() }
            }
            return result ?? self.cache[key]?.artwork ?? Artwork()
        }
        inflight[key]=task
        let result=await task.value
        if generation == ticket { inflight[key]=nil }
        return result
    }

    private func saveCache() {
        let entries = cache
        let url = Self.cacheURL
        pendingSave?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(400))
                let data = try JSONEncoder().encode(entries)
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {}
        }
    }

    private var pendingSave: Task<Void, Never>?

    static func validate(token: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.themoviedb.org/3/configuration")!, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BiliError.invalid("TMDB 没有返回有效响应") }
        guard http.statusCode == 200 else {
            if [401, 403].contains(http.statusCode) { throw BiliError.invalid("TMDB 未接受此令牌") }
            throw BiliError.http(http.statusCode)
        }
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

    private static func search(title:String,token:String,kind:Kind,year:Int?) async -> Artwork? {
        var complete = true
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
                  let results=root["results"] as? [[String:Any]] else { complete = false; continue }
            if let item = matchingTitle(in: results, title: title, year: year) {
                return Artwork(
                    poster: imageURL(item["poster_path"], size: "w780"),
                    backdrop: imageURL(item["backdrop_path"], size: "w1280")
                )
            }
        }
        return complete ? Artwork() : nil
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
    @Environment(AppPreferences.self) private var preferences
    @State private var image:NSImage?
    @State private var loading=true
    private var loadKey: String {
        [video.bvid, kind.rawValue, token, preferences.artworkRevision.uuidString].joined(separator: "|")
    }
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
        .task(id: loadKey) {
            loading = image == nil
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
    @Environment(AppPreferences.self) private var preferences
    private var signature: String {
        let ids = videos.prefix(24).map(\.bvid).joined(separator: ",")
        return [ids, kind.rawValue, token, preferences.artworkRevision.uuidString].joined(separator: "|")
    }
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
                    guard !Task.isCancelled, let video=iterator.next() else { return }
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

    private static func smallerTMDBImage(_ source: String) -> String? {
        guard URL(string: source)?.host == "image.tmdb.org" else { return nil }
        if source.contains("/w780/") { return source.replacingOccurrences(of: "/w780/", with: "/w500/") }
        if source.contains("/w1280/") { return source.replacingOccurrences(of: "/w1280/", with: "/w780/") }
        return nil
    }

    @MainActor static func load(preferred: String?, fallback: [String], width: Int, portrait: Bool) async -> NSImage? {
        var alternate: NSImage?
        for source in [preferred, preferred.flatMap(Self.smallerTMDBImage)].compactMap({ $0 }) + fallback where !source.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard let image = await RemoteImageStore.shared.image(source, width: width) else { continue }
            let ratio = image.size.width / image.size.height
            if portrait ? ratio < 1 : ratio >= 1.3 { return image }
            if portrait, source != preferred, alternate == nil { alternate = image }
        }
        return alternate
    }
}
