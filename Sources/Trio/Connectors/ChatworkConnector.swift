import Foundation

/// Chatwork API v2
struct ChatworkConnector {
    let token: String

    func fetchUnread() async throws -> [Message] {
        // /rooms で全ルーム取得 → unread_num > 0 のルームだけ /rooms/{id}/messages
        let rooms = try await call(path: "/rooms") as? [[String: Any]] ?? []
        var messages: [Message] = []
        for room in rooms {
            guard let unread = room["unread_num"] as? Int, unread > 0,
                  let roomId = room["room_id"] as? Int else { continue }
            let msgs = try await call(path: "/rooms/\(roomId)/messages?force=1") as? [[String: Any]] ?? []
            for m in msgs.suffix(unread) {
                guard let mid = m["message_id"] as? String,
                      let body = m["body"] as? String,
                      let sendTime = m["send_time"] as? TimeInterval,
                      let account = m["account"] as? [String: Any] else { continue }
                let name = account["name"] as? String ?? "unknown"
                messages.append(Message(
                    id: "cw_\(roomId)_\(mid)",
                    service: .chatwork,
                    sender: name,
                    threadId: "\(roomId)",
                    body: body,
                    receivedAt: Date(timeIntervalSince1970: sendTime)
                ))
            }
        }
        return messages
    }

    func postMessage(roomId: String, text: String) async throws {
        var req = URLRequest(url: URL(string: "https://api.chatwork.com/v2/rooms/\(roomId)/messages")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-ChatWorkToken")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "body=\(text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        req.httpBody = body.data(using: .utf8)
        _ = try await URLSession.shared.data(for: req)
    }

    private func call(path: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.chatwork.com/v2\(path)")!)
        req.setValue(token, forHTTPHeaderField: "X-ChatWorkToken")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }
}
