import Foundation
import Network
import OSLog
import HarborCore

/// Private loopback-only DASH/fMP4 → HLS byte-range gateway. No transcoding and no remote listener.
actor MediaGateway {
    enum Resource { case text(Data), media([URL]),playlist(URL),stream(URL) }
    private var resources: [String: Resource] = [:]
    private var stopped=false
    private var requests:[UUID:Task<(Data,URLResponse),Error>]=[:]
    private var connections:[ObjectIdentifier:NWConnection]=[:]
    private static let diagnostics = Logger(subsystem: "app.biliswift.mac", category: "MediaGateway")
    private struct RangeKey: Hashable {
        let urls: [URL]
        let offset: UInt64
        let length: UInt64
    }
    private var warmTask: Task<Void, Never>?
    private var warmRanges: [RangeKey: (Data, HTTPURLResponse)] = [:]
    private var warmGeneration = UUID()

    func clearWarmRanges() {
        warmGeneration = UUID()
        warmTask?.cancel()
        warmTask = nil
        warmRanges.removeAll()
    }

    private var activeRanges: [RangeKey: Task<(Data, HTTPURLResponse), Error>] = [:]
    private var preferredCDN: [[URL]: URL] = [:]
    private var vodRoutes: [[String]] = []
    private var liveMap:[URL:String]=[:]
    private var liveOrder:[URL]=[]
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let token = UUID().uuidString
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.httpShouldSetCookies = false; c.httpCookieStorage = nil
        return URLSession(configuration:c)
    }()
    deinit {session.invalidateAndCancel()}
    func start() async throws {
        guard !stopped else {throw CancellationError()}
        if listener != nil { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos:.userInitiated))
            Task { await self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = OnceContinuation(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(nil)
                case .failed(let error): gate.resume(error)
                case .cancelled: gate.resume(BiliError.invalid("媒体网关已关闭"))
                default: break
                }
            }
            listener.start(queue: .global(qos:.userInitiated))
        }
        guard let bound = listener.port else { throw BiliError.invalid("无法启动本机媒体网关") }
        port = bound.rawValue
    }
    func stop() {
        clearWarmRanges()
        for task in activeRanges.values { task.cancel() };activeRanges.removeAll()
        stopped=true;listener?.cancel();listener=nil;resources.removeAll();vodRoutes.removeAll();preferredCDN.removeAll();liveMap.removeAll();liveOrder.removeAll()
        for request in requests.values {request.cancel()}
        for connection in connections.values {connection.cancel()};connections.removeAll()
    }
    private func accept(_ connection:NWConnection) {
        guard !stopped else {connection.cancel();return}
        connections[ObjectIdentifier(connection)]=connection
        connection.stateUpdateHandler = { [weak self,weak connection] state in
            guard let connection else{return}
            if case .cancelled=state {Task {await self?.removeConnection(connection)}}
            if case .failed=state {Task {await self?.removeConnection(connection)}}
        }
        receive(connection,buffer:Data())
    }
    private func removeConnection(_ connection:NWConnection) {connections.removeValue(forKey:ObjectIdentifier(connection))}
    private func read(_ request:URLRequest) async throws -> (Data,URLResponse) {
        guard !stopped else {throw CancellationError()}
        let id=UUID(),client=session
        let task=Task {try await client.data(for:request)}
        requests[id]=task;defer{requests.removeValue(forKey:id)}
        let response=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        guard !stopped else {throw CancellationError()};return response
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength:1, maximumLength:16384) { [weak self] data, _, complete, error in
            var updated = buffer; if let data { updated.append(data) }
            let snapshot = updated
            if snapshot.range(of:Data("\r\n\r\n".utf8)) != nil {
                Task { await self?.respond(connection, request:snapshot) }
            } else if complete || error != nil || snapshot.count >= 16384 { connection.cancel() }
            else { Task { await self?.receive(connection,buffer:snapshot) } }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) async {
        guard !stopped else {connection.cancel();return}
        do {
            guard let text = String(data:request,encoding:.utf8) else { throw BiliError.invalid("HTTP") }
            let lines = text.components(separatedBy:"\r\n")
            let first = (lines.first ?? "").split(separator:" ")
            guard first.count >= 2, first[0] == "GET", let resource = resources[String(first[1])] else {
                send(connection,status:"404 Not Found",data:Data(),type:"text/plain"); return
            }
            switch resource {
            case .text(let data): send(connection,status:"200 OK",data:data,type:"application/vnd.apple.mpegurl")
            case .playlist(let url):
                let rewritten = try await loadLivePlaylist(url)
                send(connection,status:"200 OK",data:Data(rewritten.utf8),type:"application/vnd.apple.mpegurl")
            case .stream(let url):
                let rangeLine=lines.first(where:{$0.lowercased().hasPrefix("range:")})
                let range=rangeLine.map{String($0.dropFirst(6)).trimmingCharacters(in:.whitespaces)}
                let (data,http)=try await fetchLive(url,range:range)
                let extra=http.value(forHTTPHeaderField:"Content-Range").map{"Content-Range: \($0)\r\nAccept-Ranges: bytes\r\n"} ?? ""
                send(connection,status:http.statusCode==206 ? "206 Partial Content":"200 OK",data:data,type:http.mimeType ?? "application/octet-stream",extra:extra)
            case .media(let urls):
                guard let rangeLine = lines.first(where:{$0.lowercased().hasPrefix("range:")}) else { throw BiliError.invalid("缺少媒体范围") }
                let range = rangeLine.dropFirst(6).trimmingCharacters(in:.whitespaces)
                guard range.hasPrefix("bytes=") else { throw BiliError.invalid("无效范围") }
                let span = try ByteSpan(String(range.dropFirst(6)))
                guard span.length <= 128 * 1024 * 1024 else { throw BiliError.invalid("分段过大") }
                let (data,http) = try await fetch(urls,span:span)
                let total = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.map(String.init) ?? "*"
                let contentRange = "bytes \(span.offset)-\(span.offset + span.length - 1)/\(total)"
                send(connection,status:"206 Partial Content",data:data,type:"video/mp4",extra:"Content-Range: \(contentRange)\r\nAccept-Ranges: bytes\r\n")
            }
        } catch {
            let issue = error as NSError
            Self.diagnostics.error("Gateway request failed domain=\(issue.domain, privacy: .public) code=\(issue.code)")
            send(connection,status:"502 Bad Gateway",data:Data("媒体分段暂不可用".utf8),type:"text/plain")
        }
    }
    private func send(_ connection:NWConnection,status:String,data:Data,type:String,extra:String = "") {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
        response.append(data)
        connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
    }
    private func fetch(_ urls:[URL],span:ByteSpan) async throws -> (Data,HTTPURLResponse) {
        let key = RangeKey(urls: urls, offset: span.offset, length: span.length)
        if let warmed = warmRanges[key] { return warmed }
        if let existing = activeRanges[key] { return try await existing.value }
        let task = Task { try await fetchFromMirrors(urls, span: span) }
        activeRanges[key] = task
        defer { activeRanges.removeValue(forKey: key) }
        return try await task.value
    }

    private func fetchFromMirrors(_ urls: [URL], span: ByteSpan) async throws -> (Data, HTTPURLResponse) {
        let preferred = preferredCDN[urls]
        let ordered = (preferred.map { [$0] } ?? []) + urls.filter { $0 != preferred }
        let candidates = Array(ordered.prefix(4))
        let firstPair = Array(candidates.prefix(2))
        if let result = try await firstAvailable(firstPair, span: span) {
            remember(result.url, for: urls)
            return (result.data, result.response)
        }
        for url in candidates.dropFirst(2) {
            do {
                let result = try await fetchChunks(url, span: span)
                remember(url, for: urls)
                return result
            } catch {
                if stopped || Task.isCancelled { throw CancellationError() }
            }
        }
        throw BiliError.invalid("所有片源镜像均无法读取，请刷新播放地址或检查网络。")
    }

    private func firstAvailable(_ urls: [URL], span: ByteSpan) async throws -> (url: URL, data: Data, response: HTTPURLResponse)? {
        // Avoid downloading a second large copy while the primary transfer is in progress.
        if span.length > 8 * 1024 * 1024 || urls.count < 2 {
            for url in urls {
                do {
                    let (data, response) = try await fetchChunks(url, span: span)
                    return (url, data, response)
                } catch {
                    try Task.checkCancellation()
                }
            }
            return nil
        }
        return try await withThrowingTaskGroup(of: (URL, Data, HTTPURLResponse)?.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    if index > 0 { try await Task.sleep(for: .milliseconds(700)) }
                    do {
                        let (data, response) = try await self.fetchChunks(url, span: span)
                        return (url, data, response)
                    } catch {
                        try Task.checkCancellation()
                        return nil
                    }
                }
            }
            while let candidate = try await group.next() {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return nil
        }
    }

    private func remember(_ url: URL, for urls: [URL]) {
        if preferredCDN.count >= 72 { preferredCDN.removeAll(keepingCapacity: true) }
        preferredCDN[urls] = url
    }

    private func fetchChunks(_ url: URL, span: ByteSpan) async throws -> (Data, HTTPURLResponse) {
        let chunkSize: UInt64 = 32 * 1024 * 1024
        guard span.length > chunkSize else { return try await fetchOne(url, span: span) }

        var data = Data()
        var response: HTTPURLResponse?
        var remaining = span.length
        var offset = span.offset
        while remaining > 0 {
            let length = min(chunkSize, remaining)
            let (part, http) = try await fetchOne(url, span: ByteSpan(offset: offset, length: length))
            data.append(part)
            response = http
            remaining -= length
            if remaining > 0 { offset += length }
        }
        guard let response else { throw BiliError.invalid("无效的媒体分段") }
        return (data, response)
    }

    private func fetchOne(_ url:URL,span:ByteSpan) async throws -> (Data,HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(span.header,forHTTPHeaderField:"Range")
        request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
        request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        let started = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await read(request)
        } catch {
            let issue = error as NSError
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            Self.diagnostics.error("Range failed host=\(url.host ?? "-", privacy: .public) offset=\(span.offset) length=\(span.length) ms=\(elapsed) domain=\(issue.domain, privacy: .public) code=\(issue.code)")
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        if elapsed >= 750 || status != 206 || data.count != Int(span.length) {
            Self.diagnostics.notice("Range host=\(url.host ?? "-", privacy: .public) offset=\(span.offset) length=\(span.length) status=\(status) bytes=\(data.count) ms=\(elapsed)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206, data.count == Int(span.length), MediaTrack.allowedHost(http.url?.host),
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              range.hasPrefix("bytes \(span.offset)-\(span.offset + span.length - 1)/") else {
            throw BiliError.invalid("片源不支持安全的分段读取，或播放地址已过期")
        }
        return (data,http)
    }
    private func fetchLive(_ url:URL,range:String?=nil) async throws -> (Data,HTTPURLResponse) {
        guard url.scheme=="https",MediaTrack.allowedHost(url.host) else {throw BiliError.invalid("不受信任的直播资源")}
        var request=URLRequest(url:url, timeoutInterval: 8)
        request.setValue("https://live.bilibili.com/",forHTTPHeaderField:"Referer")
        request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        if let range {guard range.hasPrefix("bytes=") else {throw BiliError.invalid("无效范围")};request.setValue(range,forHTTPHeaderField:"Range")}
        let (data,response)=try await read(request)
        guard let http=response as? HTTPURLResponse,[200,206].contains(http.statusCode),MediaTrack.allowedHost(http.url?.host),data.count<=64*1024*1024 else {throw BiliError.invalid("直播资源读取失败")}
        return (data,http)
    }
    private func liveRoute(_ raw:String,base:URL) throws -> String {
        guard let url=URL(string:raw,relativeTo:base)?.absoluteURL,url.scheme=="https",MediaTrack.allowedHost(url.host) else {throw BiliError.invalid("直播包含不受支持的资源地址")}
        if let path=liveMap[url] {return path}
        let playlist=url.path.lowercased().hasSuffix(".m3u8")
        let path="/\(token)/live/\(UUID().uuidString)"+(playlist ? ".m3u8":".bin")
        resources[path]=playlist ? .playlist(url):.stream(url);liveMap[url]=path
        if !playlist {
            liveOrder.append(url)
            while liveOrder.count>512 {let old=liveOrder.removeFirst();if let route=liveMap.removeValue(forKey:old){resources.removeValue(forKey:route)}}
        }
        return path
    }
    private func rewritePlaylist(_ text:String,base:URL) throws -> String {
        let regex=try NSRegularExpression(pattern:"URI=\"([^\"]+)\"")
        return try text.components(separatedBy:.newlines).map { line in
            if line.isEmpty {return line}
            if !line.hasPrefix("#") {return try liveRoute(line.trimmingCharacters(in:.whitespaces),base:base)}
            var result=line
            for match in regex.matches(in:line,range:NSRange(line.startIndex...,in:line)).reversed() {
                guard let valueRange=Range(match.range(at:1),in:line),let replacementRange=Range(match.range(at:1),in:result) else {continue}
                result.replaceSubrange(replacementRange,with:try liveRoute(String(line[valueRange]),base:base))
            }
            return result
        }.joined(separator:"\n")
    }
    private func loadLivePlaylist(_ url: URL) async throws -> String {
        let (data, response) = try await fetchLive(url)
        guard data.count < 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U"),
              !text.contains("com.apple.streamingkeydelivery") else {
            throw BiliError.invalid("不支持的直播播放列表")
        }
        return try rewritePlaylist(text, base: response.url ?? url)
    }

    func prepareLive(_ url:URL) async throws -> URL {
        try await start()
        _ = try await loadLivePlaylist(url)
        try Task.checkCancellation()
        let path=try liveRoute(url.absoluteString,base:url)
        return URL(string:"http://127.0.0.1:\(port)\(path)")!
    }
    private func segments(for track: MediaTrack?) async throws -> [MediaSegment]? {
        guard let track else { return nil }
        let (index, _) = try await fetch(track.urls, span: track.index)
        return try SegmentIndex.parse(index, absoluteOffset: track.index.offset)
    }

    func prepare(video:MediaTrack,audio:MediaTrack?,warmAt:Double?=nil) async throws -> URL {
        try await start()
        var prepared: [String: Resource] = [:]
        let generation = UUID().uuidString
        let base = "/\(token)/\(generation)"
        let videoPath = base + "/video.mp4"
        async let videoSegmentsRequest = segments(for: video)
        async let audioSegmentsRequest = segments(for: audio)
        let (videoSegments, audioSegments) = try await (videoSegmentsRequest, audioSegmentsRequest)
        guard let videoSegments else { throw BiliError.invalid("缺少视频索引") }
        prepared[videoPath] = .media(video.urls)
        prepared[base+"/video.m3u8"] = .text(Data(SegmentIndex.playlist(track:video,segments:videoSegments,resource:videoPath).utf8))
        var lines = ["#EXTM3U","#EXT-X-VERSION:7"]
        var codecs = video.codec
        var bandwidth = video.bandwidth
        if let audio, let segments = audioSegments {
            let path = base+"/audio.mp4"
            prepared[path] = .media(audio.urls)
            prepared[base+"/audio.m3u8"] = .text(Data(SegmentIndex.playlist(track:audio,segments:segments,resource:path).utf8))
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(base)/audio.m3u8\"")
            codecs += "," + audio.hlsCodec; bandwidth += audio.bandwidth
        }
        var attributes = "BANDWIDTH=\(max(1,bandwidth)),CODECS=\"\(codecs)\",RESOLUTION=\(video.width)x\(video.height)"
        if audio != nil { attributes += ",AUDIO=\"audio\"" }
        if video.quality == 125 || video.codec.hasPrefix("dvh1.05.") || video.codec.hasPrefix("dvhe.05.") { attributes += ",VIDEO-RANGE=PQ" }
        // Dolby Vision and immersive audio remain experimental until real-device validation.
        lines += ["#EXT-X-STREAM-INF:"+attributes,base+"/video.m3u8"]
        prepared[base+"/master.m3u8"] = .text(Data((lines.joined(separator:"\n")+"\n").utf8))
        guard !stopped, !Task.isCancelled else { throw CancellationError() }
        resources.merge(prepared) { _, new in new }
        vodRoutes.append(Array(prepared.keys))
        if vodRoutes.count > 18 {
            for route in vodRoutes.removeFirst() { resources.removeValue(forKey: route) }
        }
        if let warmAt {
            clearWarmRanges()
            let ticket = warmGeneration
            warmTask = Task(priority: .utility) { [weak self] in
                guard let self else { return }
                async let videoWarm: Void = self.warm(video, segments: videoSegments, at: warmAt, ticket: ticket)
                async let audioWarm: Void = self.warm(audio, segments: audioSegments ?? [], at: warmAt, ticket: ticket)
                _ = await (videoWarm, audioWarm)
            }
        }
        return URL(string:"http://127.0.0.1:\(port)\(base)/master.m3u8")!
    }
    private func warm(_ track: MediaTrack?, segments: [MediaSegment], at position: Double, ticket: UUID) async {
        guard let track else { return }
        var end = 0.0
        let segment = segments.first {
            end += $0.duration
            return end > position
        }
        for span in [track.initialization, segment?.span].compactMap({ $0 }) {
            guard warmGeneration == ticket, !Task.isCancelled else { return }
            if span.length > 4 * 1024 * 1024 { continue }
            guard let result = try? await fetch(track.urls, span: span),
                  warmGeneration == ticket, !Task.isCancelled else { continue }
            warmRanges[RangeKey(urls: track.urls, offset: span.offset, length: span.length)] = result
        }
    }

}
private final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void,Error>?
    init(_ continuation:CheckedContinuation<Void,Error>) { self.continuation = continuation }
    func resume(_ error:Error?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        if let error { c?.resume(throwing:error) } else { c?.resume() }
    }
}
