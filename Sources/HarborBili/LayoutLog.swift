import Foundation

enum LayoutLog {
    static func write(_ line:String) {
        let text="\(Date().timeIntervalSince1970) \(line)\n"
        let url=URL(fileURLWithPath:"/tmp/biliswift-layout.log")
        if let handle=try? FileHandle(forWritingTo:url) {
            handle.seekToEndOfFile();handle.write(Data(text.utf8));try? handle.close()
        } else {
            try? text.write(to:url,atomically:true,encoding:.utf8)
        }
    }
}
