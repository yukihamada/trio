import Foundation

/// Slack API: conversations.history + users.info でDM/mentionを取得
struct SlackConnector {
    let token: String  // xoxp- or xoxb-

    func fetchUnread() async throws -> [Message] {
        // 1. conversations.list (types=im,mpim) で自分のDMチャンネル取得
        let channels = try await call("conversations.list", query: ["types": "im,mpim", "limit": "50"])
        guard let chs = channels["channels"] as? [[String: Any]] else { return [] }

        var messages: [Message] = []
        for ch in chs {
            guard let chId = ch["id"] as? String else { continue }
            let unreadCount = ch["unread_count_display"] as? Int ?? 0
            guard unreadCount > 0 else { continue }

            let hist = try await call("conversations.history", query: [
                "channel": chId, "limit": "\(min(unreadCount, 20))"
            ])
            guard let msgs = hist["messages"] as? [[String: Any]] else { continue }
            for m in msgs {
                guard let ts = m["ts"] as? String,
                      let text = m["text"] as? String,
                      let user = m["user"] as? String else { continue }
                let ts_ = Double(ts) ?? 0
                messages.append(Message(
                    id: "slack_\(chId)_\(ts)",
                    service: .slack,
                    sender: user,
                    threadId: chId,
                    body: text,
                    receivedAt: Date(timeIntervalSince1970: ts_)
                ))
            }
        }
        return messages
    }

    func postMessage(channel: String, text: String) async throws {
        var req = URLRequest(url: URL(string: "https://slack.com/api/chat.postMessage")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["channel": channel, "text": text])
        _ = try await URLSession.shared.data(for: req)
    }

    private func call(_ method: String, query: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://slack.com/api/\(method)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
