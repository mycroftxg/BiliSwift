import SwiftUI
import AppKit
import CryptoKit

@MainActor @Observable final class UpdateController {
    private static let repository = "mycroftxg/BiliSwift"
    private static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    private static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    private struct UpdateError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }

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
        let filename: String
        let size: Int64?
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
            if let http = response as? HTTPURLResponse, [403, 429].contains(http.statusCode) {
                release = try await checkReleasePage()
            } else {
                try Self.requireOK(response)
                let info = try JSONDecoder().decode(Release.self, from: data)
                guard !info.draft, !info.prerelease else {
                    throw UpdateError("GitHub 尚未发布稳定版本")
                }
                if let version = try newerVersion(for: info.tag_name) {
                    let filename = "BiliSwift-\(version).dmg"
                    guard let asset = info.assets.first(where: { $0.name == filename && $0.state == "uploaded" }),
                          asset.size > 0, let digest = Self.sha256(from: asset.digest) else {
                        throw UpdateError("GitHub 尚未提供完整安装包及校验信息")
                    }
                    release = makeUpdate(version: version, notes: info.notes, size: asset.size, digest: digest)
                }
            }
            status = release.map { "发现新版本 \($0.version)" } ?? "已是最新版本（\(currentVersion)）"
        } catch {
            status = ""
            self.error = "检查更新失败：\(error.localizedDescription)"
        }
    }

    private func newerVersion(for tag: String) throws -> String? {
        let version = String(tag.dropFirst())
        guard tag.hasPrefix("v"), let latest = Self.versionParts(version),
              let current = Self.versionParts(currentVersion) else {
            throw UpdateError("GitHub 发布版本格式不受支持")
        }
        return current.lexicographicallyPrecedes(latest) ? version : nil
    }

    private func makeUpdate(version: String, notes: String?, size: Int64?, digest: String) -> Update {
        let tag = "v" + version
        let filename = "BiliSwift-\(version).dmg"
        let page = Self.releasesURL.appending(path: "tag").appending(path: tag)
        let url = Self.releasesURL.appending(path: "download").appending(path: tag).appending(path: filename)
        return Update(version: version, notes: notes, filename: filename, size: size, digest: digest, url: url, page: page)
    }

    private func checkReleasePage() async throws -> Update? {
        let (_, response) = try await session.data(from: Self.releasesURL.appending(path: "latest"))
        try Self.requireOK(response)
        guard let page = response.url, page.host == Self.releasesURL.host,
              page.path == Self.releasesURL.appending(path: "tag").appending(path: page.lastPathComponent).path else {
            throw UpdateError("GitHub 限制了 API 请求，暂时无法确认最新发布版本")
        }
        let tag = page.lastPathComponent
        guard let version = try newerVersion(for: tag) else { return nil }
        let assetsPage = Self.releasesURL.appending(path: "expanded_assets").appending(path: tag)
        let (data, assetsResponse) = try await session.data(from: assetsPage)
        try Self.requireOK(assetsResponse)
        let assetPath = "/\(Self.repository)/releases/download/\(tag)/BiliSwift-\(version).dmg"
        guard assetsResponse.url?.host == assetsPage.host,
              let digest = Self.releasePageDigest(in: String(decoding: data, as: UTF8.self), assetPath: assetPath) else {
            throw UpdateError("GitHub 限制了 API 请求，发布页暂未提供可验证的安装包")
        }
        return makeUpdate(version: version, notes: nil, size: nil, digest: digest)
    }

    nonisolated static func releasePageDigest(in html: String, assetPath: String) -> String? {
        let rows = html.components(separatedBy: "</li>")
        guard let row = rows.first(where: { $0.contains("href=\"\(assetPath)\"") }),
              let range = row.range(of: #"value="sha256:[a-fA-F0-9]{64}""#, options: .regularExpression) else {
            return nil
        }
        return sha256(from: String(row[range].dropFirst(7).dropLast()))
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
                    try Self.verify(file, size: release.size, digest: release.digest)
                }.value
                try Task.checkCancellation()

                let folder = FileManager.default.temporaryDirectory
                    .appending(path: "BiliSwift-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: release.filename)
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
            throw UpdateError("无效的 HTTPS 响应")
        }
        guard http.statusCode == 200 else { throw UpdateError("GitHub 或下载镜像返回 HTTP \(http.statusCode)") }
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

    nonisolated static func verify(_ file: URL, size: Int64?, digest: String) throws {
        let actualSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let actualSize, actualSize > 0, size == nil || Int64(actualSize) == size else {
            throw UpdateError("安装包大小与 GitHub 发布记录不一致")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
        }
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == digest else { throw UpdateError("安装包 SHA-256 校验失败") }
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
