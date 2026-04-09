import Foundation

/// Claude Haiku 4.5 に全未読メッセージを一括で送り、重要度スコアと返信案を生成。
struct ClaudeBatcher {
    let config: LLMConfig
    let model = "claude-haiku-4-5-20251001"

    init(config: LLMConfig) { self.config = config }

    struct TriageResult: Codable {
        let id: String
        let score: Double
        let reason: String
        let replies: [ReplyOption]

        struct ReplyOption: Codable {
            let text: String
            let tone: String
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            if let d = try? c.decode(Double.self, forKey: .score) {
                self.score = d
            } else if let i = try? c.decode(Int.self, forKey: .score) {
                self.score = Double(i)
            } else if let s = try? c.decode(String.self, forKey: .score) {
                self.score = Double(s) ?? 0.0
            } else {
                self.score = 0.0
            }
            self.reason = (try? c.decode(String.self, forKey: .reason)) ?? ""

            if let arr = try? c.decode([ReplyOption].self, forKey: .replies) {
                self.replies = arr
            } else if let single = try? c.decode(String.self, forKey: .reply) {
                let tone = (try? c.decode(String.self, forKey: .tone)) ?? "polite"
                self.replies = [ReplyOption(text: single, tone: tone)]
            } else {
                self.replies = []
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(score, forKey: .score)
            try c.encode(reason, forKey: .reason)
            try c.encode(replies, forKey: .replies)
        }

        enum CodingKeys: String, CodingKey { case id, score, reason, replies, reply, tone }
    }

    // MARK: - Main entry

    /// MainActorから呼び出す際、profileとhistoryは値スナップショットとして渡す
    func triage(
        messages: [Message],
        profileSnapshot: UserProfile.Profile? = nil,
        historyByMessageId: [String: [StateStore.PersistedMessage]] = [:]
    ) async throws -> [TriageResult] {
        guard !messages.isEmpty else { return [] }
        let chunkSize = 20
        if messages.count > chunkSize {
            let chunks = stride(from: 0, to: messages.count, by: chunkSize).map {
                Array(messages[$0..<min($0+chunkSize, messages.count)])
            }
            var allResults: [TriageResult] = []
            for chunk in chunks {
                let r = try await triageChunk(chunk, profileSnapshot: profileSnapshot, historyByMessageId: historyByMessageId)
                allResults.append(contentsOf: r)
            }
            return allResults
        }
        return try await triageChunk(messages, profileSnapshot: profileSnapshot, historyByMessageId: historyByMessageId)
    }

    // MARK: - Chunk processing

    private func triageChunk(
        _ messages: [Message],
        profileSnapshot: UserProfile.Profile?,
        historyByMessageId: [String: [StateStore.PersistedMessage]]
    ) async throws -> [TriageResult] {
        let iso = ISO8601DateFormatter()

        // 各メッセージに履歴とプロファイル情報を付加
        let input: [[String: Any]] = messages.map { m in
            var dict: [String: Any] = [
                "id": m.id,
                "service": m.service.rawValue,
                "sender": m.sender,
                "body": String(m.body.prefix(300)),
                "received_at": iso.string(from: m.receivedAt)
            ]
            if let history = historyByMessageId[m.id], !history.isEmpty {
                dict["history"] = history.map { h -> [String: Any] in
                    [
                        "body": String(h.body.prefix(150)),
                        "at": iso.string(from: h.receivedAt)
                    ]
                }
            }
            if let p = profileSnapshot, let meta = p.contacts[m.sender] {
                var ctx: [String: Any] = [:]
                if !meta.relationship.isEmpty { ctx["relationship"] = meta.relationship }
                if meta.totalExchanges > 0 { ctx["past_count"] = meta.totalExchanges }
                if !meta.preferredTone.isEmpty { ctx["preferred_tone"] = meta.preferredTone }
                if !ctx.isEmpty { dict["contact_context"] = ctx }
            }
            return dict
        }

        // システムプロンプト (プロファイル情報込み)
        var systemParts: [String] = [
            "あなたはメッセージトリアージアシスタントです。",
            "ユーザーの代わりに多様な返信案を生成します。",
            "",
            "【出力仕様】",
            "各メッセージに対して以下を含むJSONオブジェクトを配列で返してください:",
            "- id: 入力のidそのまま",
            "- score: 重要度 0.0〜1.0",
            "- reason: 日本語で1行、なぜこのスコアか",
            "- replies: 8〜10個の異なる選択肢の返信案 [{text, tone}]",
            "",
            "【重要】repliesは多様なバリエーションを出してください。以下のtone種別からできるだけ多く (8個以上):",
            "- yes: 承諾/肯定 (短めシンプル)",
            "- yes_polite: 丁寧な承諾",
            "- yes_detail: 具体的な承諾 (日時・条件付き)",
            "- no: 辞退/否定",
            "- no_polite: 丁寧な辞退と代替案提示",
            "- ask: 質問で返す (単純な1問)",
            "- ask_detail: 複数の確認事項を含む質問",
            "- later: 保留/延期",
            "- detail: 詳細な回答を含む長文",
            "- casual: カジュアル・絵文字多用",
            "- emoji: スタンプ/絵文字メインの短文",
            "- thanks: お礼中心",
            "- suggest: 提案/アイデア",
            "",
            "同じ内容の言い換えは避け、**意図や方向性が本当に違う** 選択肢を並べてください。",
            "",
            "【重要】履歴(history)があれば過去の会話の流れを踏まえ、",
            "ユーザーの過去の文体や、その送信者との関係性を考慮してください。",
            "",
            "text は自然な日本語 (長さは内容に合わせて)。",
            "JSON配列のみ出力、コードブロック不要。"
        ]

        if let p = profileSnapshot {
            var profileLines: [String] = ["", "【返信者 (=ユーザー) のプロファイル】"]
            if !p.fullName.isEmpty { profileLines.append("名前: \(p.fullName)") }
            if !p.email.isEmpty { profileLines.append("メール: \(p.email)") }
            if !p.bio.isEmpty { profileLines.append("自己紹介: \(p.bio)") }
            if !p.signature.isEmpty { profileLines.append("署名: \(p.signature)") }
            systemParts.append(contentsOf: profileLines)

            // サンプル0件 → 「初回」モードで日本語ビジネスメッセージの典型例を示す
            if p.writingSamples.isEmpty {
                systemParts.append(contentsOf: [
                    "",
                    "【Few-shot: 初回起動 — 標準的な日本語メッセージスタイル】",
                    "ユーザーの過去送信サンプルがまだ無いので、以下の日本語の自然な返信例を参考にしてください。",
                    "",
                    "例1. 受信「明日の会議参加できますか？」→「はい、参加します。よろしくお願いします。」",
                    "例2. 受信「見積もり送ってください」→「承知しました。本日中にお送りします。」",
                    "例3. 受信「ちょっと時間ある？」→「大丈夫だよ、何？」",
                    "例4. 受信「誕生日おめでとう！」→「ありがとう！嬉しいよ😊」",
                    "例5. 受信「資料確認お願いします」→「確認しました、問題なさそうです！」",
                    "",
                    "日本人が自然に書く敬語/カジュアルの程度を、受信メッセージのトーンに合わせて調整してください。"
                ])
            }

            // Few-shot: 相手ごと・一般の過去返信を例示
            if !p.writingSamples.isEmpty {
                var fewshot: [String] = [
                    "",
                    "【Few-shot: ユーザーの過去の返信スタイル】",
                    "以下はユーザーが実際に過去に送信した返信です。文体、語尾、絵文字の使い方、改行の癖、呼び方などを学習し、",
                    "同じトーン・雰囲気で新しい返信案を生成してください。",
                    ""
                ]

                // 各メッセージに対応した類似送信者の返信例を集める
                // 全般例 (最新5件)
                fewshot.append("◆ 全般的な過去の返信例:")
                for (i, s) in p.writingSamples.prefix(8).enumerated() {
                    if let incoming = s.incomingBody, !incoming.isEmpty {
                        fewshot.append("例\(i+1). [\(s.recipient) から] 受信: 「\(incoming.prefix(80))」")
                        fewshot.append("     → ユーザーの返信: 「\(s.text.prefix(120))」 (tone=\(s.tone))")
                    } else {
                        fewshot.append("例\(i+1). ユーザーの返信: 「\(s.text.prefix(120))」 (tone=\(s.tone))")
                    }
                }

                // 各入力メッセージの送信者ごとに、その人宛の過去返信もあれば追加
                let allSenders = Set(messages.map { $0.sender })
                let contactSpecific = p.writingSamples
                    .filter { allSenders.contains($0.recipient) }
                    .prefix(5)
                if !contactSpecific.isEmpty {
                    fewshot.append("")
                    fewshot.append("◆ 今回の送信者宛の過去返信 (関係性・語尾調整用):")
                    for s in contactSpecific {
                        if let incoming = s.incomingBody, !incoming.isEmpty {
                            fewshot.append("- [\(s.recipient)] 「\(incoming.prefix(60))」→「\(s.text.prefix(100))」")
                        } else {
                            fewshot.append("- [\(s.recipient)] 「\(s.text.prefix(100))」")
                        }
                    }
                }

                fewshot.append("")
                fewshot.append("【重要】上記例の文体を真似して返信案を生成してください。")
                fewshot.append("- 敬語レベル、絵文字の有無、改行の癖、一人称、呼び方を合わせる")
                fewshot.append("- その送信者宛の過去返信があれば、そのトーンを最優先")
                systemParts.append(contentsOf: fewshot)
            }
        }

        let system = systemParts.joined(separator: "\n")

        let inputJson = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        let userText = "未読メッセージ一覧:\n" + (String(data: inputJson, encoding: .utf8) ?? "[]")

        let payload: [String: Any]
        if config.isCloud {
            payload = ["messages": input, "system": system]
        } else {
            payload = [
                "model": model,
                "max_tokens": 8192,
                "system": system,
                "messages": [["role": "user", "content": userText]]
            ]
        }

        var req = URLRequest(url: URL(string: config.endpoint)!)
        req.httpMethod = "POST"
        req.setValue(config.authValue, forHTTPHeaderField: config.authHeader)
        if !config.isCloud {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        let dbg = "[\(Date())] [claude] status=\(status) body[0..300]=\(bodyStr.prefix(300))\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/trio.log")) {
            h.seekToEndOfFile()
            h.write(dbg.data(using: .utf8)!)
            try? h.close()
        }

        let text: String
        if config.isCloud {
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = root["results"] {
                let resultsData = try JSONSerialization.data(withJSONObject: results)
                return (try? JSONDecoder().decode([TriageResult].self, from: resultsData)) ?? []
            }
            text = String(data: data, encoding: .utf8) ?? "[]"
        } else {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = root["content"] as? [[String: Any]],
                  let first = content.first,
                  let t = first["text"] as? String
            else {
                throw NSError(domain: "ClaudeBatcher", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            text = t
        }

        var cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]") {
            cleaned = String(cleaned[start...end])
        }
        let jsonData = cleaned.data(using: .utf8) ?? Data()
        do {
            return try JSONDecoder().decode([TriageResult].self, from: jsonData)
        } catch {
            let dbg = "[\(Date())] [claude] decode failed: \(error). cleaned[0..300]=\(cleaned.prefix(300))\n"
            if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/trio.log")) {
                h.seekToEndOfFile()
                h.write(dbg.data(using: .utf8)!)
                try? h.close()
            }
            return []
        }
    }
}
