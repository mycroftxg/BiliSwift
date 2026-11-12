import SwiftUI
import HarborCore

struct MessagesView: View {
    let refreshID: UUID
    @Environment(AccountSession.self) private var account
    @State private var tab = "reply"
    @State private var items: [JSON] = []
    @State private var loading = false
    @State private var error: String?
    @State private var login = false
    @State private var retryID = UUID()

    private let tabs = [("reply", "回复我的"), ("at", "@我的"), ("like", "收到的赞")]

    private struct LoadKey: Equatable {
        let accountID: Int
        let tab: String
        let refreshID: UUID
        let retryID: UUID
    }

    var body: some View {
        Group {
            if account.loggedIn {
                VStack(spacing: 0) {
                    Picker("消息分类", selection: $tab) {
                        ForEach(tabs, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 330)
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    Divider()
                    inbox
                }
            } else {
                ContentUnavailableView {
                    Label("登录后查看消息", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("登录") { login = true }.buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("消息")
        .task(id: LoadKey(accountID: account.mid, tab: tab, refreshID: refreshID, retryID: retryID)) {
            await load()
        }
        .sheet(isPresented: $login) { LoginSheet().environment(account) }
    }

    @ViewBuilder private var inbox: some View {
        if loading {
            ProgressView("正在加载消息…").frame(maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("消息加载失败", systemImage: "exclamationmark.bubble")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { retryID = UUID() }.buttonStyle(.glass)
            }
        } else if items.isEmpty {
            ContentUnavailableView("暂无消息", systemImage: "tray")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        messageRow(items[index])
                        if index < items.count - 1 {
                            Divider().padding(.leading, 68).padding(.trailing, 18)
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: 740)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func load() async {
        items = []
        error = nil
        guard account.loggedIn else { loading = false; return }
        loading = true
        do {
            let feed = try await BiliAPI.shared.msgFeed(tab)
            guard !Task.isCancelled else { return }
            items = feed["items"].array
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func messageRow(_ item: JSON) -> some View {
        let user = item["user"]
        let reply = item["reply"]
        let source = item["item"]
        let name = user["nickname"].string
        let context = source["title"].string
        let stamp = [item["time"], item["reply_time"], item["at_time"], item["like_time"]]
            .map(\.int).first(where: { $0 > 0 })
        let message = [reply["content"]["message"].string, source["content"].string, context]
            .first(where: { !$0.isEmpty }) ?? (tab == "like" ? "给你点了个赞" : "收到一条消息")
        let video = linkedVideo(user: user, reply: reply, source: source)

        return HStack(alignment: .top, spacing: 14) {
            AvatarView(source: user["avatar"].string, size: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name.isEmpty ? "哔哩哔哩用户" : name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let stamp {
                        Text(Date(timeIntervalSince1970: TimeInterval(stamp)),
                             format: .dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(message)
                    .font(.body)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !context.isEmpty, context != message {
                    Label(context, systemImage: "play.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            if let video {
                NavigationLink(value: AppRoute.video(video)) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("打开相关视频")
                .accessibilityLabel("打开相关视频")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func linkedVideo(user: JSON, reply: JSON, source: JSON) -> Video? {
        let link = [source["uri"], reply["uri"], source["source"]].map(\.string)
            .first { $0.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) != nil }
        guard let link, let range = link.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) else {
            return nil
        }
        return Video(.object([
            "bvid": .string(String(link[range])),
            "aid": .number(Double(source["source"].int != 0 ? source["source"].int : reply["oid"].int)),
            "title": .string(source["title"].string.isEmpty ? reply["title"].string : source["title"].string),
            "pic": .string(source["image_urls"].array.first?.string ?? ""),
            "author": .string(user["nickname"].string), "mid": user["mid"]
        ]))
    }
}
