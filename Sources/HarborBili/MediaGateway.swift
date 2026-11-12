import Foundation
import Network
import HarborCore

/// Private loopback-only DASH/fMP4 → HLS byte-range gateway. No transcoding and no remote listener.
actor MediaGateway {
    enum Resource { case text(Data), media([URL]),playlist(URL),stream(URL) }
    private var resources: [String: Resource] = [:]
    private var stopped=false
    private var requests:[UUID:Task<(Data,URLResponse),Error>]=[:]
    private var connections:[ObjectIdentifier:NWConnection]=[:]
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
        stopped=true;listener?.cancel();listener=nil;resources.removeAll();liveMap.removeAll();liveOrder.removeAll()
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
                let (data,_)=try await fetchLive(url)
                guard data.count<2*1024*1024,let text=String(data:data,encoding:.utf8),text.hasPrefix("#EXTM3U"),!text.contains("com.apple.streamingkeydelivery") else {throw BiliError.invalid("不支持的直播播放列表")}
                let rewritten=try rewritePlaylist(text,base:url)
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
                guard span.length <= 32 * 1024 * 1024 else { throw BiliError.invalid("分段过大") }
                let (data,http) = try await fetch(urls,span:span)
                let contentRange = http.value(forHTTPHeaderField:"Content-Range") ?? "bytes \(span.offset)-\(span.offset+span.length-1)/*"
                send(connection,status:"206 Partial Content",data:data,type:"video/mp4",extra:"Content-Range: \(contentRange)\r\nAccept-Ranges: bytes\r\n")
            }
        } catch { send(connection,status:"502 Bad Gateway",data:Data("媒体分段暂不可用".utf8),type:"text/plain") }
    }
    private func send(_ connection:NWConnection,status:String,data:Data,type:String,extra:String = "") {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n".utf8)
        response.append(data)
        connection.send(content:response,completion:.contentProcessed { _ in connection.cancel() })
    }
    private func fetch(_ urls:[URL],span:ByteSpan) async throws -> (Data,HTTPURLResponse) {
        for url in urls.prefix(4) {
            do { return try await fetchOne(url,span:span) }
            catch is CancellationError { throw CancellationError() }
            catch { if stopped || Task.isCancelled { throw CancellationError() } }
        }
        throw BiliError.invalid("所有片源镜像均无法读取，请刷新播放地址或检查网络。")
    }
    private func fetchOne(_ url:URL,span:ByteSpan) async throws -> (Data,HTTPURLResponse) {
        var request = URLRequest(url:url)
        request.setValue(span.header,forHTTPHeaderField:"Range")
        request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
        request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        let (data,response) = try await read(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206, data.count == Int(span.length), MediaTrack.allowedHost(http.url?.host) else {
            throw BiliError.invalid("片源不支持安全的分段读取，或播放地址已过期")
        }
        return (data,http)
    }
    private func fetchLive(_ url:URL,range:String?=nil) async throws -> (Data,HTTPURLResponse) {
        guard url.scheme=="https",MediaTrack.allowedHost(url.host) else {throw BiliError.invalid("不受信任的直播资源")}
        var request=URLRequest(url:url)
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
    func prepareLive(_ url:URL) async throws -> URL {
        try await start()
        let path=try liveRoute(url.absoluteString,base:url)
        return URL(string:"http://127.0.0.1:\(port)\(path)")!
    }
    func prepare(video:MediaTrack,audio:MediaTrack?) async throws -> URL {
        try await start()
        // Keep prior routes alive until the old AVPlayerItem releases them, bounded per player session.
        if resources.count > 90 { resources.removeAll() }
        let generation = UUID().uuidString
        let base = "/\(token)/\(generation)"
        let videoPath = base + "/video.mp4"
        let (videoIndex,_) = try await fetch(video.urls,span:video.index)
        let videoSegments = try SegmentIndex.parse(videoIndex,absoluteOffset:video.index.offset)
        resources[videoPath] = .media(video.urls)
        resources[base+"/video.m3u8"] = .text(Data(SegmentIndex.playlist(track:video,segments:videoSegments,resource:videoPath).utf8))
        var lines = ["#EXTM3U","#EXT-X-VERSION:7"]
        var codecs = video.codec
        var bandwidth = video.bandwidth
        if let audio {
            let path = base+"/audio.mp4"
            let (index,_) = try await fetch(audio.urls,span:audio.index)
            let segments = try SegmentIndex.parse(index,absoluteOffset:audio.index.offset)
            resources[path] = .media(audio.urls)
            resources[base+"/audio.m3u8"] = .text(Data(SegmentIndex.playlist(track:audio,segments:segments,resource:path).utf8))
            lines.append("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(base)/audio.m3u8\"")
            codecs += "," + audio.codec; bandwidth += audio.bandwidth
        }
        var attributes = "BANDWIDTH=\(max(1,bandwidth)),CODECS=\"\(codecs)\",RESOLUTION=\(video.width)x\(video.height)"
        if audio != nil { attributes += ",AUDIO=\"audio\"" }
        if video.quality == 125 { attributes += ",VIDEO-RANGE=PQ" }
        // Dolby Vision and immersive audio remain experimental until real-device validation.
        lines += ["#EXT-X-STREAM-INF:"+attributes,base+"/video.m3u8"]
        resources[base+"/master.m3u8"] = .text(Data((lines.joined(separator:"\n")+"\n").utf8))
        return URL(string:"http://127.0.0.1:\(port)\(base)/master.m3u8")!
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
