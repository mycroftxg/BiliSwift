import Foundation

public struct QRCodeChallenge:Sendable { public let url:String,key:String }
public struct QRLoginResult:Sendable { public let code:Int,message:String,cookies:[HTTPCookie] }
public actor QRLoginClient {
    private let session:URLSession
    public init() {
        let config=URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest=15
        session=URLSession(configuration:config)
    }
    private func get(_ path:String,_ params:[String:String]=[:]) async throws -> (JSON,[HTTPCookie]) {
        var c=URLComponents(string:"https://passport.bilibili.com"+path)!
        c.percentEncodedQuery=WBI.query(params)
        var request=URLRequest(url:c.url!)
        request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        request.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
        let (data,response)=try await session.data(for:request)
        guard let http=response as? HTTPURLResponse,http.statusCode==200 else { throw BiliError.invalid("登录服务暂时不可用") }
        let root=try JSONDecoder().decode(JSON.self,from:data)
        guard root["code"].int==0 else { throw BiliError.server(root["code"].int,root["message"].string) }
        var headers:[String:String]=[:]
        for (key,value) in http.allHeaderFields { headers[String(describing:key)]=String(describing:value) }
        let cookies=HTTPCookie.cookies(withResponseHeaderFields:headers,for:request.url!) + (session.configuration.httpCookieStorage?.cookies ?? [])
        return (root["data"],cookies)
    }
    public func generate() async throws -> QRCodeChallenge {
        let (data,_)=try await get("/x/passport-login/web/qrcode/generate")
        guard let url=URL(string:data["url"].string),url.scheme=="https",["passport.bilibili.com","account.bilibili.com"].contains(url.host ?? ""),!data["qrcode_key"].string.isEmpty else { throw BiliError.invalid("二维码响应无效") }
        return QRCodeChallenge(url:url.absoluteString,key:data["qrcode_key"].string)
    }
    public func poll(_ challenge:QRCodeChallenge) async throws -> QRLoginResult {
        let (data,cookies)=try await get("/x/passport-login/web/qrcode/poll",["qrcode_key":challenge.key])
        return QRLoginResult(code:data["code"].int,message:data["message"].string,cookies:cookies)
    }
}
