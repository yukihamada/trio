import Foundation

/// Trio Cloud サーバとのリレー
/// - Mac が定期的にメッセージ状態をサーバにアップロード (Web閲覧用)
/// - サーバに溜まった送信コマンドをポーリングして実行
@MainActor
final class ServerRelay {
    static let shared = ServerRelay()
    private var pollTimer: Timer?

    var serverURL: String {
        TrioSettings.trioCloudURL
    }

    /// 定期アップロード + コマンドポーリング開始 (30秒間隔)
    func start(store: AppStore) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                await self.uploadState(store: store)
                await self.pollCommands(store: store)
            }
        }
        // 即時実行
        Task {
            await uploadState(store: store)
        }
    }

    /// メッセージ状態をサーバにアップロード (Web閲覧用、平文JSON)
    func uploadState(store: AppStore) async {
        let token = store.settings.trioCloudToken
        guard !token.isEmpty else { return }
        tlog("[relay] uploading \(store.messages.filter { $0.status == .pending }.count) pending msgs")

        let pending = store.messages.filter { $0.status == .pending }
        let payload: [[String: Any]] = pending.map { m in
            var dict: [String: Any] = [
                "id": m.id,
                "service": m.service.rawValue,
                "sender": m.sender,
                "body": m.body,
                "receivedAt": ISO8601DateFormatter().string(from: m.receivedAt),
                "importanceScore": m.importanceScore,
                "reasonForPriority": m.reasonForPriority ?? "",
                "status": m.status.rawValue,
                "serviceDisplayName": m.serviceDisplayName
            ]
            dict["drafts"] = m.drafts.map { d in
                ["text": d.text, "tone": d.tone] as [String: Any]
            }
            return dict
        }

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: URL(string: "\(serverURL)/v1/web/state")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    /// サーバからコマンドをポーリングして実行
    func pollCommands(store: AppStore) async {
        let token = store.settings.trioCloudToken
        guard !token.isEmpty else { return }

        var req = URLRequest(url: URL(string: "\(serverURL)/v1/web/commands")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }

        guard let commands = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for cmd in commands {
            guard let action = cmd["action"] as? String,
                  let messageId = cmd["message_id"] as? String else { continue }

            if action == "send",
               let replyText = cmd["reply_text"] as? String,
               let message = store.messages.first(where: { $0.id == messageId }) {
                await store.send(message: message, draftIndex: 0, overrideText: replyText, fromWeb: true)
            } else if action == "skip",
                      let message = store.messages.first(where: { $0.id == messageId }) {
                store.skip(message: message)
            }
        }
    }
}
