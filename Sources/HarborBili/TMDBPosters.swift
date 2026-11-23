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
        var alternatives: [String]? = nil
        var tmdbID: Int? = nil
        var backdropCandidates: [String] { [backdrop].compactMap { $0 } + (alternatives ?? []) }

    }
    private struct Cached: Codable {
        let artwork: Artwork
        let expires: Date
    }
    private static let cacheURL = URL.cachesDirectory.appending(path: "BiliSwift/tmdb-artwork-v2.json")
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

    func artwork(for video: Video, detail: JSON = .null, token: String, kind: Kind) async -> Artwork {
        let titles = [detail["title"].string, video.title, detail["origin_name"].string,
                      detail["jp_title"].string, detail["original_title"].string]
        let year = Self.year(from: detail["publish"]["pub_time"].string)
            ?? Self.year(from: video.author)
        let result = await artwork(titles: titles, token: token, kind: kind, year: year, seasonID: video.seasonID.flatMap { $0 > 0 ? $0 : nil })
        guard result.backdrop == nil, !token.isEmpty, !Task.isCancelled,
              case .null = detail, let id = video.seasonID, id > 0,
              let season = try? await BiliAPI.shared.season(id) else { return result }
        return await artwork(for: video, detail: season, token: token, kind: kind)
    }

    private func artwork(titles: [String], token: String, kind: Kind, year: Int?, seasonID: Int?) async -> Artwork {
        let value=token.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty else { return Artwork() }
        var seen = Set<String>()
        let queries = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard let title = queries.first else { return Artwork() }
        let fingerprint = SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let key = "\(fingerprint)|\(kind.rawValue)|\(seasonID.map(String.init) ?? title)"
        if let hit = cache[key], hit.expires > .now, hit.artwork.backdrop != nil { return hit.artwork }
        let queryKey = key + "|" + queries.joined(separator: "|") + "|\(year ?? 0)"
        if let hit = cache[queryKey], hit.expires > .now { return hit.artwork }
        if let task = inflight[queryKey] { return await task.value }
        let ticket = generation
        let task=Task<Artwork,Never> {
            let result = await Self.search(titles: queries, token: value, kind: kind, year: year)
            guard self.generation == ticket, !Task.isCancelled else { return Artwork() }
            if let result {
                let found = result.poster != nil || result.backdrop != nil
                let entry = Cached(artwork: result, expires: Date().addingTimeInterval(result.backdrop != nil ? 604800 : 1800))
                self.cache[queryKey] = entry
                if result.backdrop != nil { self.cache[key] = entry }
                if self.cache.count > 600 {
                    self.cache = Dictionary(uniqueKeysWithValues: self.cache.sorted { $0.value.expires > $1.value.expires }.prefix(500).map { ($0.key, $0.value) })
                }
                if found { self.saveCache() }
            }
            return result ?? self.cache[key]?.artwork ?? Artwork()
        }
        inflight[queryKey]=task
        let result=await task.value
        if generation == ticket { inflight[queryKey]=nil }
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
        let kind = Kind(seasonType: detail["type"].int)
        let artwork = await artwork(for: video, detail: detail, token: token, kind: kind)
        let fallback = [detail["bkg_cover"].string]
            + detail["episodes"].array.prefix(3).map { $0["cover"].string }
        return await SeasonArtwork.load(preferred: artwork.backdropCandidates, fallback: fallback, width: width, portrait: false)
    }

    private static func request(_ path: String, token: String, query: [URLQueryItem] = []) async throws -> JSON {
        var components = URLComponents(string: "https://api.themoviedb.org/3/" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 6)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiliError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    static func seriesTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"(?i)\s*(?:第[0-9一二三四五六七八九十]+季|season\s+\d+)\s*$"#,
                                   with: "", options: .regularExpression)
    }

    private static func seasonNumber(in title: String) -> Int? {
        let suffix = title.dropFirst(seriesTitle(title).count)
        if let range = suffix.range(of: #"[0-9]+"#, options: .regularExpression) {
            return Int(suffix[range])
        }
        let numbers = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        return numbers.firstIndex { suffix.contains("第" + $0 + "季") }.map { $0 + 1 }
    }

    private static func search(titles: [String], token: String, kind: Kind, year: Int?) async -> Artwork? {
        struct Query {
            let title: String
            let year: Int?
        }
        var queries = titles.prefix(3).map { Query(title: $0, year: year) }
        if kind == .tv, let first = titles.first {
            let base = seriesTitle(first)
            if !base.isEmpty, base != first { queries.append(Query(title: base, year: nil)) }
        }
        var complete = true
        for query in queries {
            for language in ["zh-CN", "en-US"] {
                if Task.isCancelled { return nil }
                do {
                    let response = try await request("search/\(kind.rawValue)", token: token, query: [
                        .init(name: "query", value: query.title), .init(name: "language", value: language),
                        .init(name: "include_adult", value: "false")
                    ])
                    let rows = response["results"].array.compactMap { row -> [String: Any]? in
                        guard case .object(let object) = row else { return nil }
                        return object.mapValues(\.string)
                    }
                    guard let item = matchingTitle(in: rows, title: query.title, year: query.year),
                          let id = Int(item["id"] as? String ?? ""), id > 0 else { continue }
                    var artwork = Artwork(poster: imageURL(item["poster_path"], size: "w780"),
                                          backdrop: imageURL(item["backdrop_path"], size: "w1280"), tmdbID: id)
                    do {
                        let gallery = try await request("\(kind.rawValue)/\(id)/images", token: token)
                        let ranked = gallery["backdrops"].array.filter { $0["aspect_ratio"].double >= 1.3 }.sorted {
                            let left = abs($0["aspect_ratio"].double - 16.0 / 9.0)
                            let right = abs($1["aspect_ratio"].double - 16.0 / 9.0)
                            if left != right { return left < right }
                            return $0["vote_count"].int > $1["vote_count"].int
                        }
                        var seen = Set([artwork.backdrop].compactMap { $0 })
                        let urls = ranked.compactMap { imageURL($0["file_path"].string, size: "w1280") }
                            .filter { seen.insert($0).inserted }
                        if artwork.backdrop == nil { artwork.backdrop = urls.first }
                        artwork.alternatives = Array(urls.filter { $0 != artwork.backdrop }.prefix(3))
                        if artwork.poster == nil {
                            artwork.poster = gallery["posters"].array.lazy
                                .filter { $0["aspect_ratio"].double > 0 && $0["aspect_ratio"].double < 1 }
                                .compactMap { imageURL($0["file_path"].string, size: "w780") }.first
                        }
                    } catch {
                        if artwork.backdrop == nil { return nil }
                    }
                    if kind == .tv, let season = titles.lazy.compactMap({ seasonNumber(in: $0) }).first, season > 0,
                       let gallery = try? await request("tv/\(id)/season/\(season)/images", token: token),
                       let poster = gallery["posters"].array.lazy
                            .filter({ $0["aspect_ratio"].double > 0 && $0["aspect_ratio"].double < 1 })
                            .compactMap({ imageURL($0["file_path"].string, size: "w780") }).first {
                        artwork.poster = poster
                    }
                    return artwork
                } catch BiliError.http(let code) where [401, 403, 429].contains(code) {
                    return nil
                } catch {
                    complete = false
                }
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
            let poster = await TMDBPosters.shared.artwork(for: video, token: token, kind: kind).poster
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
                    group.addTask { _=await TMDBPosters.shared.artwork(for:video,token:token,kind:kind) }
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
        await load(preferred: [preferred].compactMap { $0 }, fallback: fallback, width: width, portrait: portrait)
    }

    @MainActor static func load(preferred: [String], fallback: [String], width: Int, portrait: Bool) async -> NSImage? {
        var alternate: NSImage?
        let candidates = preferred.flatMap { [$0, smallerTMDBImage($0)].compactMap { $0 } }
        for source in candidates + fallback where !source.isEmpty {
            guard !Task.isCancelled else { return nil }
            guard let image = await RemoteImageStore.shared.image(source, width: width) else { continue }
            let ratio = image.size.width / image.size.height
            if portrait ? ratio < 1 : ratio >= 1.3 { return image }
            if portrait, !candidates.contains(source), alternate == nil { alternate = image }
        }
        return alternate
    }
}
