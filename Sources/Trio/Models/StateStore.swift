import Foundation

/// `~/Library/Application Support/Trio/state.json` にMessageとReplyDraftを永続化
/// - 差分triage: 既処理メッセージはAPI呼ばずにキャッシュ復元
/// - 再起動後も status (replied/skipped) が残る
@MainActor
final class StateStore {
    static let shared = StateStore()

    struct PersistedMessage: Codable {
        var id: String
        var service: String
        var sender: String
        var threadId: String?
        var body: String
        var receivedAt: Date
        var status: String
        var importanceScore: Double
        var reasonForPriority: String?
        var drafts: [PersistedDraft] = []
        var processedAt: Date
    }

    struct PersistedDraft: Codable {
        var text: String
        var tone: String
    }

    struct AppState: Codable {
        var messages: [String: PersistedMessage] = [:]
        var lastRefreshed: Date?
        var version: Int = 1
    }

    private(set) var state: AppState = AppState()
    private let fileURL: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Trio", isDirectory: true)
        ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Trio")

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("state.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder.trio.decode(AppState.self, from: data)
        else { return }
        self.state = decoded
    }

    func save() {
        do {
            let data = try JSONEncoder.trio.encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            tlog("[state] save failed: \(error)")
        }
    }

    /// 既処理でスコア有りのMessage ID一覧
    func processedIds() -> Set<String> {
        Set(state.messages.values.filter { $0.importanceScore > 0 }.map { $0.id })
    }

    /// キャッシュからMessageを復元
    func restore(into messages: inout [Message]) {
        for (i, m) in messages.enumerated() {
            if let p = state.messages[m.id] {
                m.status = MessageStatus(rawValue: p.status) ?? .pending
                m.importanceScore = p.importanceScore
                m.reasonForPriority = p.reasonForPriority
                m.drafts = p.drafts.map { ReplyDraft(text: $0.text, tone: $0.tone) }
                messages[i] = m
            }
        }
    }

    /// Messageを保存
    func persist(_ messages: [Message]) {
        for m in messages {
            var p = state.messages[m.id] ?? PersistedMessage(
                id: m.id,
                service: m.service.rawValue,
                sender: m.sender,
                threadId: m.threadId,
                body: m.body,
                receivedAt: m.receivedAt,
                status: m.status.rawValue,
                importanceScore: m.importanceScore,
                reasonForPriority: m.reasonForPriority,
                drafts: [],
                processedAt: .now
            )
            p.status = m.status.rawValue
            p.importanceScore = m.importanceScore
            p.reasonForPriority = m.reasonForPriority
            p.drafts = m.drafts.map { PersistedDraft(text: $0.text, tone: $0.tone) }
            p.processedAt = .now
            state.messages[m.id] = p
        }
        state.lastRefreshed = .now
        save()
    }

    /// 古いエントリを削除 (14日より古い)
    func pruneOldEntries(olderThan days: Double = 14) {
        let cutoff = Date().addingTimeInterval(-days * 86400)
        state.messages = state.messages.filter { $0.value.receivedAt > cutoff }
    }

    /// エクスポート (再インストール時のバックアップ用)
    func exportAll() -> URL? {
        let backup: [String: Any] = [
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: .now),
            "state": state
        ]
        var combined = state
        _ = backup
        _ = combined
        // state.json をそのまま返す
        return fileURL
    }

    /// データディレクトリのURL (ユーザーが Finder で開けるよう)
    var dataDirectory: URL {
        fileURL.deletingLastPathComponent()
    }

    /// 同じ送信者(またはスレッド)の過去メッセージを取得 (新しい順)
    func conversationHistory(for message: Message, limit: Int = 8) -> [PersistedMessage] {
        let all = state.messages.values
        let related = all.filter { p in
            // 同じ送信者かつ同じサービス (スレッド一致 > 送信者一致)
            guard p.id != message.id else { return false }
            if let threadId = message.threadId, !threadId.isEmpty,
               p.threadId == threadId {
                return true
            }
            return p.sender == message.sender && p.service == message.service.rawValue
        }
        return related
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(limit)
            .map { $0 }
    }
}

extension JSONEncoder {
    static let trio: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let trio: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
