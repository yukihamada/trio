import Foundation

/// 全メッセージを俯瞰してAIが返信方針をグループ化 + 提案
/// ユーザーは方針を確認・編集してから一括実行する
struct ReplyPlanner {
    let config: LLMConfig

    /// AIからの方針サマリ
    struct Plan: Codable {
        let summary: String       // 全体の一言サマリ
        let groups: [Group]

        struct Group: Codable, Identifiable {
            var id: String { theme }
            let theme: String              // 例: "会議招待" / "誕生日メッセージ"
            let priority: String           // "urgent" / "high" / "medium" / "low"
            let messageIds: [String]       // 対象のメッセージID
            let recommendedAction: String  // "reply" / "skip" / "later" / "custom"
            let reasoning: String          // なぜこのグループ化+推奨か
            let suggestedReply: String?    // デフォルトの返信案 (nilならユーザー入力必要)
            let tone: String?              // 推奨tone
        }
    }

    /// 全メッセージからプランを生成
    func plan(messages: [Message], profileSnapshot: UserProfile.Profile? = nil) async throws -> Plan {
        guard !messages.isEmpty else {
            return Plan(summary: "未読メッセージはありません", groups: [])
        }

        let iso = ISO8601DateFormatter()
        let input: [[String: Any]] = messages.map { m in
            [
                "id": m.id,
                "service": m.service.rawValue,
                "sender": m.sender,
                "body": String(m.body.prefix(250)),
                "at": iso.string(from: m.receivedAt),
                "score": m.importanceScore
            ]
        }

        var systemParts: [String] = [
            "あなたはユーザーのメッセージ返信戦略アシスタントです。",
            "全メッセージを俯瞰し、以下を出力してください:",
            "",
            "1. summary: 全体状況の1-2文サマリ",
            "2. groups: テーマ別にグループ化した返信方針 (3-8グループ)",
            "",
            "各groupは:",
            "- theme: グループ名 (例: '会議招待', '誕生日祝い', '仕事の質問', 'スパム')",
            "- priority: urgent (緊急) / high (重要) / medium (通常) / low (低)",
            "- messageIds: そのグループに属するメッセージIDの配列",
            "- recommendedAction: 'reply' (返信する) / 'skip' (無視) / 'later' (あとで) / 'custom' (個別判断)",
            "- reasoning: なぜこの方針か (1行)",
            "- suggestedReply: デフォルト返信案 (同じような返信でOKなグループ)",
            "- tone: yes/no/ask/later/detail/casual/emoji",
            "",
            "【重要】",
            "- 似たメッセージは同じグループに (誕生日祝いは全部まとめる等)",
            "- スパム・通知系は separate group にして skip 推奨",
            "- 緊急かつ個別対応必要なものは個別group (messageId 1件)",
            "- 同じ返信で済むものは一つのsuggestedReplyで束ねる",
            "",
            "JSON形式のみ出力、コードブロック不要。"
        ]

        if let p = profileSnapshot {
            if !p.fullName.isEmpty {
                systemParts.append("")
                systemParts.append("【ユーザー名】\(p.fullName)")
            }
            if !p.writingSamples.isEmpty {
                systemParts.append("【文体サンプル】")
                for s in p.writingSamples.prefix(3) {
                    systemParts.append("- \(s.text.prefix(60))")
                }
            }
        }

        let system = systemParts.joined(separator: "\n")
        let inputJson = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        let userText = "全未読メッセージ:\n" + (String(data: inputJson, encoding: .utf8) ?? "[]")

        let payload: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": userText]]
        ]

        var req = URLRequest(url: URL(string: config.endpoint)!)
        req.httpMethod = "POST"
        req.setValue(config.authValue, forHTTPHeaderField: config.authHeader)
        if !config.isCloud {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else {
            throw NSError(domain: "ReplyPlanner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid Claude response"])
        }

        var cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = cleaned.firstIndex(of: "{"), let e = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[s...e])
        }

        let jsonData = cleaned.data(using: .utf8) ?? Data()
        return try JSONDecoder().decode(Plan.self, from: jsonData)
    }
}
