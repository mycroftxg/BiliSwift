import Foundation
import Compression
import Network
import HarborCore

/// 直播弹幕链路日志（便于定位问题）。
enum LiveLog {
    static func write(_ text:String) {
        guard let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first else { return }
        let url=dir.appendingPathComponent("harbor-live.log")
        let line="[\(Date().formatted(date:.omitted,time:.standard))] \(text)\n"
        if let handle=try? FileHandle(forWritingTo:url) { handle.seekToEndOfFile();handle.write(Data(line.utf8));try? handle.close() }
        else { try? Data(line.utf8).write(to:url) }
    }
}

/// 直播弹幕：用 Network.framework 自建 WebSocket（系统 URLSession 的 WS 在部分网络下握手失败），
/// 解压 zlib/brotli 包，把 DANMU_MSG 交给播放器。
@MainActor final class LiveChat {
    private var connection:NWConnection?
    private let queue=DispatchQueue(label:"harbor.livechat")
    private var buffer=Data()
    private var handshakeDone=false
    private var currentHost=""
    private var currentPort=443
    private var buvid=""
    private var uid=0
    private var cookieHeader=""
    private var candidates:[(String,Int)]=[]
    private var candidateIndex=0
    private var roomID=0
    private var token=""
    private var packets=0
    private var authenticated=false
    private var parsed=0
    private var watchdog:Task<Void,Never>?
    private var heartbeat:Task<Void,Never>?
    private let onStatus:(String)->Void
    private let onMessage:(String,String,UInt32)->Void

    init(onStatus:@escaping (String)->Void = { _ in },onMessage:@escaping (String,String,UInt32)->Void) {
        self.onStatus=onStatus
        self.onMessage=onMessage
    }

    func connect(roomID:Int) async throws {
        disconnect()
        self.roomID=roomID;token="";packets=0;parsed=0
        cookieHeader=await BiliAPI.shared.cookieHeader()
        let cookieBuvid=await BiliAPI.shared.cookieValue("buvid3")
        let cookieUid=await BiliAPI.shared.cookieValue("DedeUserID")
        buvid=cookieBuvid ?? ""
        uid=Int(cookieUid ?? "") ?? 0
        if buvid.isEmpty {
            if let spi=try? await BiliAPI.shared.request("/x/frontend/finger/spi") { buvid=spi["b_3"].string }
        }
        let info=try await BiliAPI.shared.liveDanmuInfo(roomID)
        try Task.checkCancellation()
        token=info["token"].string
        guard !token.isEmpty else { throw BiliError.invalid("直播间未返回聊天凭据。") }
        var seen=Set<String>()
        candidates=info["host_list"].array.flatMap { host -> [(String,Int)] in
            let name=host["host"].string.lowercased()
            guard name.hasSuffix(".chat.bilibili.com") else { return [] }
            let port=host["wss_port"].int
            return [port,443].compactMap { candidate in
                guard (1...65535).contains(candidate),seen.insert("\(name):\(candidate)").inserted else { return nil }
                return (name,candidate)
            }
        }
        guard !candidates.isEmpty else { throw BiliError.invalid("直播间未返回可用聊天节点。") }
        open(0)
    }

    func disconnect() {
        watchdog?.cancel();watchdog=nil
        heartbeat?.cancel();heartbeat=nil
        connection?.cancel();connection=nil
        buffer=Data();handshakeDone=false
    }

    private func open(_ index:Int) {
        guard index<candidates.count else {
            disconnect()
            onStatus("直播间聊天连接失败")
            LiveLog.write("all candidates failed")
            return
        }
        candidateIndex=index
        authenticated=false;packets=0
        onStatus("正在连接直播间聊天…")
        watchdog?.cancel();heartbeat?.cancel()
        connection?.cancel()
        let (host,port)=candidates[index]
        currentHost = host;currentPort = port
        buffer=Data();handshakeDone=false
        let parameters=NWParameters(tls:NWProtocolTLS.Options(),tcp:NWProtocolTCP.Options())
        let conn=NWConnection(host:NWEndpoint.Host(host),port:NWEndpoint.Port(rawValue:UInt16(port))!,using:parameters)
        connection=conn
        LiveLog.write("connect \(host):\(port)")
        conn.stateUpdateHandler={ [weak self] state in
            Task { @MainActor in
                guard let self,self.connection === conn else { return }
                switch state {
                case .ready: self.sendHandshake()
                case .failed(let error):
                    LiveLog.write("state failed: \(error.localizedDescription)")
                    if self.candidateIndex==index { self.open(index+1) }
                case .waiting(let error):
                    LiveLog.write("state waiting: \(error.localizedDescription)")
                case .cancelled: break
                default: break
                }
            }
        }
        conn.start(queue:queue)
        receive(conn)
        watchdog=Task { [weak self] in
            try? await Task.sleep(for:.seconds(8))
            guard let self,!Task.isCancelled,!self.authenticated,self.candidateIndex==index else { return }
            LiveLog.write("no frames on \(host), trying next")
            self.open(index+1)
        }
    }

    private func sendHandshake() {
        var keyBytes=Data(count:16)
        for i in 0..<16 { keyBytes[i]=UInt8.random(in:0...255) }
        let key=keyBytes.base64EncodedString()
        let hostHeader=currentPort==443 ? currentHost : "\(currentHost):\(currentPort)"
        let request="""
GET /sub HTTP/1.1\r
Host: \(hostHeader)\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Key: \(key)\r
Sec-WebSocket-Version: 13\r
Origin: https://live.bilibili.com\r
Cookie: \(cookieHeader.replacingOccurrences(of:"\n",with:""))\r
User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15\r
\r

"""
        connection?.send(content:request.data(using:.utf8),completion:.contentProcessed{ error in
            if let error { LiveLog.write("handshake send failed: \(error.localizedDescription)") }
        })
    }

    private func receive(_ conn:NWConnection) {
        conn.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,isComplete,error in
            Task { @MainActor in
                guard let self,self.connection === conn else { return }
                if let data,!data.isEmpty { self.consume(data) }
                guard self.connection === conn else { return }
                if let error {
                    LiveLog.write("receive error: \(error.localizedDescription)")
                    if self.candidateIndex<self.candidates.count { self.open(self.candidateIndex+1) }
                    return
                }
                if isComplete {
                    LiveLog.write("connection completed by peer")
                    self.open(self.candidateIndex+1)
                    return
                }
                self.receive(conn)
            }
        }
    }

    private func consume(_ data:Data) {
        buffer.append(data)
        if !handshakeDone {
            let marker=Data("\r\n\r\n".utf8)
            guard let range=buffer.range(of:marker) else { return }
            let header=String(decoding:buffer[..<range.upperBound],as:UTF8.self)
            handshakeDone=header.hasPrefix("HTTP/1.1 101")
            buffer=Data(buffer[range.upperBound...])
            guard handshakeDone else {
                LiveLog.write("handshake rejected")
                connection?.cancel()
                open(candidateIndex+1)
                return
            }
            LiveLog.write("handshake ok")
            sendAuth()
        }
        parseFrames()
    }

    private func sendAuth() {
        let queue=String((0..<8).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
        var fields:[String:JSON]=[
            "uid":.number(Double(uid)),
            "roomid":.number(Double(roomID)),
            "protover":.number(3),
            "platform":.string("web"),
            "type":.number(2),
            "key":.string(token),
            "support_ack":.bool(true),
            "queue_uuid":.string(queue),
            "scene":.string("room")
        ]
        if !buvid.isEmpty { fields["buvid"] = .string(buvid) }
        let auth=JSON.object(fields)
        guard let body=try? JSONEncoder().encode(auth) else { return }
        LiveLog.write("sending live chat authentication")
        sendFrame(opcode:2,payload:Self.packet(op:7,body:body))
        sendHeartbeat()
        heartbeat?.cancel()
        heartbeat=Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(30))
                guard let self,!Task.isCancelled,self.connection != nil else { return }
                self.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() {
        sendFrame(opcode:2,payload:Self.packet(op:2,body:Data("[object Object]".utf8)))
    }

    private func parseFrames() {
        while buffer.count>=2 {
            let start=buffer.startIndex
            let first=buffer[start]
            let second=buffer[start+1]
            let opcode=first & 0x0F
            let masked=(second & 0x80) != 0
            var length=Int(second & 0x7F)
            var offset=2
            if length==126 {
                guard buffer.count>=4 else { return }
                length=Int(buffer[start+2])<<8 | Int(buffer[start+3]);offset=4
            } else if length==127 {
                guard buffer.count>=10 else { return }
                var value:UInt64=0
                for i in 0..<8 { value=(value<<8)|UInt64(buffer[start+2+i]) }
                guard value<=8*1024*1024 else { open(candidateIndex+1);return }
                length=Int(value);offset=10
            }
            var mask=Data()
            if masked {
                guard buffer.count>=offset+4 else { return }
                mask=buffer.subdata(in:(start+offset)..<(start+offset+4));offset+=4
            }
            guard buffer.count>=offset+length else { return }
            var payload=buffer.subdata(in:(start+offset)..<(start+offset+length))
            if masked,!mask.isEmpty {
                for i in payload.indices { payload[i] ^= mask[(i-mask.startIndex) % 4] }
            }
            buffer.removeFirst(offset+length)
            switch opcode {
            case 8:
                LiveLog.write("server closed")
                open(candidateIndex+1)
                return
            case 9:
                sendFrame(opcode:10,payload:payload)
            case 10:
                break
            default:
                guard !payload.isEmpty else { continue }
                packets+=1
                if packets<=3 { LiveLog.write("frame \(packets) bytes \(payload.count)") }
                let current=connection
                handle(payload)
                guard connection === current else { return }
            }
        }
    }

    private func sendFrame(opcode:UInt8,payload:Data) {
        var frame=Data([0x80|opcode])
        let maskBytes:[UInt8]=[UInt8.random(in:0...255),UInt8.random(in:0...255),UInt8.random(in:0...255),UInt8.random(in:0...255)]
        let length=payload.count
        if length<126 {
            frame.append(0x80|UInt8(length))
        } else if length<=65535 {
            frame.append(0x80|126)
            frame.append(UInt8((length>>8)&0xFF));frame.append(UInt8(length&0xFF))
        } else {
            frame.append(0x80|127)
            var value=UInt64(length)
            var bytes:[UInt8]=[]
            for _ in 0..<8 { bytes.insert(UInt8(value&0xFF),at:0);value>>=8 }
            frame.append(contentsOf:bytes)
        }
        frame.append(contentsOf:maskBytes)
        var masked=payload
        if !masked.isEmpty {
            for i in masked.indices { masked[i] ^= maskBytes[(i-masked.startIndex) % 4] }
        }
        frame.append(masked)
        connection?.send(content:frame,completion:.contentProcessed{ error in
            if let error { LiveLog.write("send error: \(error.localizedDescription)") }
        })
    }

    private func handle(_ data:Data) {
        var offset=0
        while offset+16<=data.count {
            let length=Int(u32(data,offset))
            let header=Int(u16(data,offset+4))
            let version=u16(data,offset+6)
            let op=u32(data,offset+8)
            guard header>=16,length>=header,offset+length<=data.count else { break }
            let body=data.subdata(in:(offset+header)..<(offset+length))
            if version==2 { if let decoded=inflate(body,algorithm:COMPRESSION_ZLIB) { handle(decoded) } }
            else if version==3 { if let decoded=inflate(body,algorithm:COMPRESSION_BROTLI) { handle(decoded) } }
            else if op==8 {
                guard let ack=try? JSONDecoder().decode(JSON.self,from:body),
                      case .number(0)=ack["code"] else {
                    LiveLog.write("chat authentication rejected")
                    open(candidateIndex+1)
                    return
                }
                authenticated=true
                watchdog?.cancel();watchdog=nil
                onStatus("已连接，等待聊天消息…")
                LiveLog.write("chat authenticated")
            }
            else if op==5,authenticated { parse(body) }
            offset+=length
        }
    }

    private func parse(_ body:Data) {
        guard let object=try? JSONDecoder().decode(JSON.self,from:body) else { return }
        guard object["cmd"].string.hasPrefix("DANMU_MSG") else { return }
        parsed+=1
        if parsed<=2 { LiveLog.write("danmu parsed=\(parsed)") }
        let info=object["info"].array
        guard info.count>1 else { return }
        let text=info[1].string
        guard !text.isEmpty else { return }
        let user=info[2].array.count>1 ? info[2].array[1].string:""
        var color:UInt32=0xFFFFFF
        let meta=info[0].array
        if meta.count>3,meta[3].int>0 { color=UInt32(truncatingIfNeeded:meta[3].int) }
        onMessage(user,text,color)
    }

    nonisolated static func packet(op:UInt32,body:Data)->Data {
        var data=Data()
        var length=UInt32(16+body.count).bigEndian
        var header=UInt16(16).bigEndian
        var version=UInt16(1).bigEndian
        var operation=op.bigEndian
        var sequence=UInt32(1).bigEndian
        withUnsafeBytes(of:&length){ data.append(contentsOf:$0) }
        withUnsafeBytes(of:&header){ data.append(contentsOf:$0) }
        withUnsafeBytes(of:&version){ data.append(contentsOf:$0) }
        withUnsafeBytes(of:&operation){ data.append(contentsOf:$0) }
        withUnsafeBytes(of:&sequence){ data.append(contentsOf:$0) }
        data.append(body)
        return data
    }

    private func inflate(_ data:Data,algorithm:compression_algorithm)->Data? {
        guard !data.isEmpty else { return nil }
        for capacity in [max(64*1024,data.count*8),4*1024*1024] {
            var output=Data(count:capacity)
            let written=output.withUnsafeMutableBytes { destination -> Int in
                data.withUnsafeBytes { source -> Int in
                    guard let destination=destination.bindMemory(to:UInt8.self).baseAddress,
                          let source=source.bindMemory(to:UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(destination,capacity,source,data.count,nil,algorithm)
                }
            }
            if written>0 { output.removeSubrange(written..<output.count);return output }
        }
        return nil
    }

    private func u32(_ data:Data,_ offset:Int)->UInt32 {
        guard offset+4<=data.count else { return 0 }
        let base=data.startIndex+offset
        return UInt32(data[base])<<24 | UInt32(data[base+1])<<16 | UInt32(data[base+2])<<8 | UInt32(data[base+3])
    }
    private func u16(_ data:Data,_ offset:Int)->UInt16 {
        guard offset+2<=data.count else { return 0 }
        let base=data.startIndex+offset
        return UInt16(data[base])<<8 | UInt16(data[base+1])
    }
}
