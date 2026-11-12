import SwiftUI
import AppKit
import CryptoKit
import HarborCore

@MainActor @Observable final class UpdateController {
    private static let repository = "mycroftxg/BiliSwift"
    private static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    enum Source: String, CaseIterable, Identifiable {
        case auto = "自动"
        case github = "GitHub"
        case ghproxy = "gh-proxy"
        case ghproxyNet = "ghproxy.net"
        case ghfast = "GHFast"

        var id: String { rawValue }

        func downloadURL(for asset: URL) -> URL {
            switch self {
            case .auto, .github: return asset
            case .ghproxy: return URL(string: "https://gh-proxy.com/" + asset.absoluteString)!
            case .ghproxyNet: return URL(string: "https://ghproxy.net/" + asset.absoluteString)!
            case .ghfast: return URL(string: "https://ghfast.top/" + asset.absoluteString)!
            }
        }
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let state: String
        }

        let tag_name: String
        let body: String?
        let assets: [Asset]
        let draft: Bool
        let prerelease: Bool

        var notes: String? { body }
    }

    struct Update {
        let version: String
        let notes: String?
        let asset: Release.Asset
        let digest: String
        let url: URL
        let page: URL
    }

    private(set) var checking = false
    private(set) var downloading = false
    private(set) var status = ""
    private(set) var release: Update?
    private(set) var error: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }()

    func check() async {
        guard !checking, !downloading else { return }
        checking = true
        error = nil
        release = nil
        status = "正在检查更新…"
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("BiliSwift/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Self.requireOK(response)
            let info = try JSONDecoder().decode(Release.self, from: data)
            guard !info.draft, !info.prerelease, info.tag_name.hasPrefix("v"),
                  let latest = Self.versionParts(String(info.tag_name.dropFirst())),
                  let current = Self.versionParts(currentVersion) else {
                throw BiliError.invalid("GitHub 发布版本格式不受支持")
            }
            guard current.lexicographicallyPrecedes(latest) else {
                status = "已是最新版本（\(currentVersion)）"
                return
            }
            let version = String(info.tag_name.dropFirst())
            let name = "BiliSwift-\(version).dmg"
            guard let asset = info.assets.first(where: { $0.name == name && $0.state == "uploaded" }),
                  asset.size > 0,
                  let digest = Self.sha256(from: asset.digest) else {
                throw BiliError.invalid("GitHub 尚未提供完整安装包及校验信息")
            }
            let page = Self.releasesURL.appending(path: "tag").appending(path: info.tag_name)
            let url = Self.releasesURL.appending(path: "download").appending(path: info.tag_name).appending(path: name)
            release = Update(version: version, notes: info.notes, asset: asset, digest: digest, url: url, page: page)
            status = "发现新版本 \(version)"
        } catch {
            status = ""
            self.error = "检查更新失败：\(error.localizedDescription)"
        }
    }

    func downloadAndOpen(using source: Source) async {
        guard let release, !checking, !downloading else { return }
        downloading = true
        error = nil
        defer { downloading = false }
        let candidates: [Source] = source == .auto ? [.github, .ghproxy, .ghproxyNet, .ghfast] : [source]
        var failures: [String] = []
        for candidate in candidates {
            guard !Task.isCancelled else { break }
            status = "正在从 \(candidate.rawValue) 下载安装包…"
            do {
                let (file, response) = try await session.download(from: candidate.downloadURL(for: release.url))
                defer { try? FileManager.default.removeItem(at: file) }
                try Self.requireOK(response)
                status = "正在校验安装包…"
                try await Task.detached(priority: .utility) {
                    try Self.verify(file, size: release.asset.size, digest: release.digest)
                }.value
                try Task.checkCancellation()

                let folder = FileManager.default.temporaryDirectory
                    .appending(path: "BiliSwift-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: release.asset.name)
                do {
                    try FileManager.default.moveItem(at: file, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                if NSWorkspace.shared.open(destination) {
                    status = "安装包已校验。请将 BiliSwift 拖入「应用程序」完成更新。"
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                    status = "安装包已校验，请在 Finder 中打开磁盘映像。"
                }
                return
            } catch {
                failures.append("\(candidate.rawValue)：\(error.localizedDescription)")
            }
        }
        status = "发现新版本 \(release.version)"
        if !Task.isCancelled { error = failures.joined(separator: "\n") }
    }

    private static func requireOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw BiliError.invalid("无效的 HTTPS 响应")
        }
        guard http.statusCode == 200 else { throw BiliError.http(http.statusCode) }
    }

    nonisolated static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    nonisolated static func sha256(from value: String?) -> String? {
        guard let value, value.hasPrefix("sha256:") else { return nil }
        let hash = value.dropFirst(7).lowercased()
        guard hash.utf8.count == 64, hash.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return hash
    }

    nonisolated static func verify(_ file: URL, size: Int64, digest: String) throws {
        let actualSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let actualSize, Int64(actualSize) == size else {
            throw BiliError.invalid("安装包大小与 GitHub 发布记录不一致")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == digest else { throw BiliError.invalid("安装包 SHA-256 校验失败") }
    }
}

struct UpdateSourcePicker: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Picker("下载源", selection: Binding(
            get: { UpdateController.Source(rawValue: preferences.values.updateSource) ?? .auto },
            set: { preferences.values.updateSource = $0.rawValue }
        )) {
            ForEach(UpdateController.Source.allCases) { source in
                Text(source.rawValue).tag(source)
            }
        }
    }
}

struct UpdatePrompt: View {
    let updater: UpdateController
    let preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let release = updater.release {
            VStack(alignment: .leading, spacing: 16) {
                Text("BiliSwift \(release.version) 可更新").font(.title2.bold())
                Text("当前版本 \(updater.currentVersion)").foregroundStyle(.secondary)
                if let notes = release.notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 250)
                }
                UpdateSourcePicker(preferences: preferences).disabled(updater.downloading)
                if updater.downloading { ProgressView(updater.status).controlSize(.small) }
                if let error = updater.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Link("发布页", destination: release.page)
                    Spacer()
                    Button("稍后下载") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("立即下载更新") {
                        Task {
                            let source = UpdateController.Source(rawValue: preferences.values.updateSource) ?? .auto
                            await updater.downloadAndOpen(using: source)
                            if updater.error == nil { dismiss() }
                        }
                    }.keyboardShortcut(.defaultAction)
                }.disabled(updater.downloading)
            }
            .padding(24)
            .frame(width: 520)
            .interactiveDismissDisabled(updater.downloading)
        }
    }
}
