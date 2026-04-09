import Foundation
import SwiftUI
import UserNotifications

/// Trio の中央 状態管理
@MainActor
final class AppStore: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var statusText: String = ""
    @Published var selectedIds: Set<String> = []
    @Published var showSettings = false
    @Published var needsFDA = false
    @Published var needsScreenRec = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?
    @Published var showOnboarding: Bool = UserDefaults.standard.bool(forKey: "trio.onboarded") == false
    @Published var showHelp: Bool = false
    @Published var showCommandBar: Bool = false
    @Published var commandBarInput: String = ""
    @Published var commandBarProcessing: Bool = false
    @Published var commandBarResult: String? = nil
    @Published var processedCount: Int = 0
    @Published var lineScanning: Bool = false
    @Published var lineScanProgress: String = ""
    @Published var undoableMessageId: String? = nil
    @Published var undoableText: String? = nil
    @Published var undoCountdown: Int = 0
    private var undoTimer: Timer? = nil
    // 返信方針プランナー
    @Published var currentPlan: ReplyPlanner.Plan? = nil
    @Published var planGenerating: Bool = false
    @Published var showPlanner: Bool = false
    @Published var planError: String? = nil
    @Published var webURL: String? = nil  // Web閲覧用URL (トークン付き)

    let settings = TrioSettings()
    let userProfile = UserProfile.shared
    private let store = StateStore.shared
    private var refreshTimer: Timer?
    private var knownImportantIds: Set<String> = []

    init() {
        tlog("[AppStore.init] enter")
        knownImportantIds = Set(store.state.messages.values
            .filter { $0.importanceScore >= 0.8 }
            .map { $0.id })
        tlog("[AppStore.init] knownImportantIds set")
        startBackgroundRefresh()
        tlog("[AppStore.init] timer started")
        Task {
            let _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
        }
        tlog("[AppStore.init] done")
    }

    // deinitではSwift 6の制限でTimerに触れないため、stopBackgroundRefresh()で明示停止

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "trio.onboarded")
        showOnboarding = false
    }

    /// LINE全走査 (数十秒かかる)
    func runLineFullScan() async {
        guard !lineScanning else { return }
        lineScanning = true
        defer { lineScanning = false }
        lineScanProgress = "🔄 LINE全走査を開始..."
        let scanned = await LINEScraper.fetchAll(maxIterations: 40)
        lineScanProgress = "✅ LINE \(scanned.count)件取得"

        // 既存メッセージとマージ
        var collected = self.messages
        let existingIds = Set(collected.map { $0.id })
        let newOnes = scanned.filter { !existingIds.contains($0.id) }
        collected.append(contentsOf: newOnes)
        store.restore(into: &collected)
        self.messages = collected
        store.persist(collected)

        // 新しいメッセージをtriage
        if let cfg = llmConfig, !newOnes.isEmpty {
            lineScanProgress = "🤖 AIが \(newOnes.count)件を整理中..."
            let profileSnapshot = userProfile.profile
            var historyMap: [String: [StateStore.PersistedMessage]] = [:]
            for m in newOnes {
                let hist = store.conversationHistory(for: m, limit: 5)
                if !hist.isEmpty { historyMap[m.id] = hist }
            }
            do {
                let results = try await ClaudeBatcher(config: cfg).triage(
                    messages: newOnes,
                    profileSnapshot: profileSnapshot,
                    historyByMessageId: historyMap
                )
                let map: [String: ClaudeBatcher.TriageResult] = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
                for m in newOnes {
                    if let r = map[m.id] {
                        m.importanceScore = r.score
                        m.reasonForPriority = r.reason
                        m.drafts.removeAll()
                        for opt in r.replies {
                            m.drafts.append(ReplyDraft(text: opt.text, tone: opt.tone))
                        }
                    }
                }
                store.persist(newOnes)
                lineScanProgress = "✨ 完了 (新規 \(results.count) 件)"
            } catch {
                lineScanProgress = "⚠️ AI処理エラー"
            }
        }
        objectWillChange.send()
    }

    // MARK: - Selection

    var selectedCount: Int { selectedIds.count }
    func isSelected(_ id: String) -> Bool { selectedIds.contains(id) }
    func toggleSelected(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }
    func clearSelection() { selectedIds.removeAll() }

    func sendSelected() async {
        let targets = messages.filter { selectedIds.contains($0.id) }
        for m in targets { await send(message: m) }
        clearSelection()
    }

    func regenerateDraft(message: Message) {
        guard let cfg = llmConfig else { return }
        Task {
            do {
                message.importanceScore = 0
                let profileSnapshot = userProfile.profile
                let hist = store.conversationHistory(for: message, limit: 5)
                let results = try await ClaudeBatcher(config: cfg).triage(
                    messages: [message],
                    profileSnapshot: profileSnapshot,
                    historyByMessageId: hist.isEmpty ? [:] : [message.id: hist]
                )
                if let r = results.first {
                    message.importanceScore = r.score
                    message.reasonForPriority = r.reason
                    message.drafts.removeAll()
                    for opt in r.replies {
                        message.drafts.append(ReplyDraft(text: opt.text, tone: opt.tone))
                    }
                    store.persist([message])
                    objectWillChange.send()
                }
            } catch {
                lastError = "再生成エラー: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Tokens

    var slackToken: String? {
        let v = settings.slackToken
        if !v.isEmpty { return v }
        return ProcessInfo.processInfo.environment["SLACK_TOKEN"] ?? Self.readEnv(key: "SLACK_TOKEN")
    }
    var chatworkToken: String? {
        let v = settings.chatworkToken
        if !v.isEmpty { return v }
        return ProcessInfo.processInfo.environment["CHATWORK_TOKEN"] ?? Self.readEnv(key: "CHATWORK_TOKEN")
    }
    var llmConfig: LLMConfig? {
        if let cfg = settings.resolveLLMConfig() { return cfg }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? Self.readEnv(key: "ANTHROPIC_API_KEY") {
            return LLMConfig(endpoint: "https://api.anthropic.com/v1/messages",
                             authHeader: "x-api-key", authValue: env, isCloud: false)
        }
        return nil
    }

    // MARK: - Derived

    var topThree: [Message] {
        Array(messages
            .filter { $0.status == .pending }
            .sorted { $0.importanceScore > $1.importanceScore }
            .prefix(3))
    }

    var pendingCount: Int {
        messages.filter { $0.status == .pending }.count
    }

    // MARK: - Refresh (差分処理)

    func refresh() async {
        if isLoading {
            tlog("[refresh] skipped (already running)")
            return
        }
        tlog("[refresh] start")
        isLoading = true
        defer { isLoading = false }
        lastError = nil
        statusText = "📬 収集中..."
        restoreSnoozedMessages()

        // 1. 通知DB (数十ms)
        var collected = NotificationDBReader.fetchRecent(hours: 48)
            .filter { settings.isServiceEnabled($0.service) }
        tlog("[refresh] notifDB: \(collected.count) msgs")
        needsFDA = NotificationDBReader.isFDAMissing()

        // 2. キャッシュ復元 → 即UIに反映 (爆速! AI待たずに既知メッセージが並ぶ)
        store.restore(into: &collected)
        for m in collected {
            userProfile.observeIncoming(sender: m.sender, service: m.service.rawValue)
        }
        self.messages = collected
        self.lastRefreshed = Date()
        statusText = "📬 \(collected.count)件 (キャッシュから復元、最新取得中...)"

        // 3. LINE OCR (既存実装、より精度高い専用パーサー)
        if LINEScraper.isAvailable() && settings.isServiceEnabled(.line) {
            let lineMsgs = await LINEScraper.fetch()
            tlog("[refresh] LINE OCR: \(lineMsgs.count) msgs")
            if !lineMsgs.isEmpty {
                let existingIds = Set(collected.map { $0.id })
                let newLine = lineMsgs.filter { !existingIds.contains($0.id) }
                collected.append(contentsOf: newLine)
            }
        }

        // 3b. 汎用OCR (Discord/Messenger/WhatsApp/Telegram/Teams等)
        let ocrServices: [Service] = [.slack, .chatwork, .discord, .telegram, .messenger, .whatsapp, .teams, .instagram]
        for svc in ocrServices where settings.isServiceEnabled(svc) && AppOCRScraper.isAppRunning(for: svc) {
            // API設定済みなら OCR スキップ (Slack/Chatwork)
            if svc == .slack && slackToken != nil { continue }
            if svc == .chatwork && chatworkToken != nil { continue }
            let msgs = await AppOCRScraper.fetch(for: svc)
            tlog("[refresh] \(svc.rawValue) OCR: \(msgs.count) msgs")
            if !msgs.isEmpty {
                let existingIds = Set(collected.map { $0.id })
                let newOnes = msgs.filter { !existingIds.contains($0.id) }
                collected.append(contentsOf: newOnes)
            }
        }

        // 統一してリストア
        store.restore(into: &collected)
        self.messages = collected

        // 4. Slack / Chatwork (API)
        if let t = slackToken {
            do {
                let s = try await SlackConnector(token: t).fetchUnread()
                let existingIds = Set(collected.map { $0.id })
                collected.append(contentsOf: s.filter { !existingIds.contains($0.id) })
            } catch {
                tlog("[refresh] slack error: \(error)")
            }
        }
        if let t = chatworkToken {
            do {
                let c = try await ChatworkConnector(token: t).fetchUnread()
                let existingIds = Set(collected.map { $0.id })
                collected.append(contentsOf: c.filter { !existingIds.contains($0.id) })
            } catch {
                tlog("[refresh] chatwork error: \(error)")
            }
        }
        store.restore(into: &collected)
        self.messages = collected

        // 4. 未処理のもの (importanceScore=0 かつ pending) だけAI処理
        let needsTriage = collected.filter {
            $0.importanceScore == 0 && $0.status == .pending
        }
        tlog("[refresh] needs triage: \(needsTriage.count) / \(collected.count)")

        if needsTriage.isEmpty {
            statusText = "✅ \(collected.count)件取得済み (キャッシュ利用)"
        } else if let cfg = llmConfig {
            statusText = "🤖 AIが \(needsTriage.count) 件を整理中..."
            do {
                // スナップショット作成 (MainActor境界を越えるため)
                let profileSnapshot = userProfile.profile
                var historyMap: [String: [StateStore.PersistedMessage]] = [:]
                for m in needsTriage {
                    let hist = store.conversationHistory(for: m, limit: 5)
                    if !hist.isEmpty { historyMap[m.id] = hist }
                }
                let results = try await ClaudeBatcher(config: cfg).triage(
                    messages: needsTriage,
                    profileSnapshot: profileSnapshot,
                    historyByMessageId: historyMap
                )
                tlog("[refresh] triage results: \(results.count)")
                let map: [String: ClaudeBatcher.TriageResult] = Dictionary(
                    uniqueKeysWithValues: results.map { ($0.id, $0) }
                )
                for m in needsTriage {
                    if let r = map[m.id] {
                        m.importanceScore = r.score
                        m.reasonForPriority = r.reason
                        m.drafts.removeAll()
                        for opt in r.replies {
                            m.drafts.append(ReplyDraft(text: opt.text, tone: opt.tone))
                        }
                    } else {
                        m.importanceScore = 0.01
                        m.reasonForPriority = "AIから応答なし"
                    }
                }
                statusText = "✨ \(results.count)件の返信案を生成しました"
            } catch {
                tlog("[refresh] triage error: \(error)")
                let errStr = "\(error)"
                if errStr.contains("credit balance") || errStr.contains("Your credit") {
                    lastError = "💳 Anthropic APIのクレジット残高が不足しています"
                } else if errStr.contains("authentication") || errStr.contains("invalid x-api-key") {
                    lastError = "🔑 APIキーが無効です — 設定から新しいキーを入力してください"
                } else if errStr.contains("rate") {
                    lastError = "⏳ リクエスト過多 — 少し待ってから再試行します"
                } else {
                    lastError = "⚠️ AI接続エラー: \(error.localizedDescription)"
                }
                statusText = ""
            }
        } else {
            lastError = "🔑 まずはAPIキーを設定してください (歯車アイコンから)"
        }

        // 5. 永続化
        store.persist(collected)
        store.pruneOldEntries()

        // 6. 高重要度の新着をmacOS通知で知らせる
        let newImportant = collected.filter {
            $0.status == .pending &&
            $0.importanceScore >= 0.8 &&
            !knownImportantIds.contains($0.id)
        }
        for m in newImportant.prefix(3) {
            await postNotification(message: m)
            knownImportantIds.insert(m.id)
        }

        // 最終反映
        self.messages = collected
        self.lastRefreshed = Date()
        tlog("[refresh] done: \(collected.count) msgs, pending: \(pendingCount)")
    }

    // MARK: - Actions

    func send(message: Message, draftIndex: Int = 0, overrideText: String? = nil, fromWeb: Bool = false) async {
        guard draftIndex < message.drafts.count else { return }
        let draft = message.drafts[draftIndex]
        let textToSend = overrideText ?? draft.text

        // 送信前確認 (Mac UI からの場合のみ、Web経由はWeb側で確認済)
        if settings.confirmBeforeSend && !fromWeb {
            let alert = NSAlert()
            alert.messageText = "この返信を送信しますか？"
            alert.informativeText = """
            宛先: \(message.sender)
            サービス: \(message.serviceDisplayName)

            ──── 送信内容 ────
            \(textToSend)
            ────────────────

            ※ 送信後3秒以内なら取り消し可能
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "送信する")
            alert.addButton(withTitle: "やめる")
            alert.icon = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)
            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        let dispatcher = Dispatcher(slackToken: slackToken, chatworkToken: chatworkToken)
        do {
            try await dispatcher.send(message: message, replyText: textToSend)
            message.status = .replied
            processedCount += 1
            store.persist([message])
            userProfile.recordSent(
                text: textToSend,
                tone: draft.tone,
                recipient: message.sender,
                incomingBody: String(message.body.prefix(300)),
                service: message.service.rawValue
            )
            startUndoTimer(messageId: message.id, text: textToSend)
            objectWillChange.send()
        } catch {
            let msg = error.localizedDescription
            if msg.contains("クリップボード") {
                // クリップボードコピー成功 (直接送信非対応サービス)
                lastError = msg
                // ステータスは replied に (ユーザーが手動ペーストする前提)
                message.status = .replied
                processedCount += 1
                store.persist([message])
                startUndoTimer(messageId: message.id, text: textToSend)
                objectWillChange.send()
            } else {
                lastError = "⚠️ 送信失敗: \(msg)"
            }
        }
    }

    /// 3秒の送信取り消しタイマー
    private func startUndoTimer(messageId: String, text: String) {
        undoTimer?.invalidate()
        undoableMessageId = messageId
        undoableText = text
        undoCountdown = 3
        undoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.undoCountdown -= 1
                if self.undoCountdown <= 0 {
                    self.undoableMessageId = nil
                    self.undoableText = nil
                    self.undoTimer?.invalidate()
                    self.undoTimer = nil
                }
            }
        }
    }

    /// 送信取り消し: statusをpendingに戻す
    func undoLastSend() {
        guard let id = undoableMessageId,
              let m = messages.first(where: { $0.id == id }) else { return }
        m.status = .pending
        processedCount = max(0, processedCount - 1)
        store.persist([m])
        undoableMessageId = nil
        undoableText = nil
        undoCountdown = 0
        undoTimer?.invalidate()
        objectWillChange.send()
    }

    // MARK: - LLM コマンドバー

    /// 自然言語指示で全未読メッセージを一括処理
    func executeCommand() async {
        guard !commandBarInput.isEmpty, let cfg = llmConfig else {
            commandBarResult = "⚠️ コマンドまたはAPIキーが設定されていません"
            return
        }
        commandBarProcessing = true
        defer { commandBarProcessing = false }
        commandBarResult = "🤖 処理中..."

        let pending = messages.filter { $0.status == .pending }
        guard !pending.isEmpty else {
            commandBarResult = "未処理メッセージがありません"
            return
        }

        let iso = ISO8601DateFormatter()
        let input: [[String: Any]] = pending.map { m in
            [
                "id": m.id,
                "sender": m.sender,
                "service": m.service.rawValue,
                "body": String(m.body.prefix(200)),
                "at": iso.string(from: m.receivedAt)
            ]
        }

        let system = """
        あなたはメッセージ一括処理アシスタントです。
        ユーザーが自然言語で指示を出します。
        未読メッセージのうち、指示に該当するものを特定し、それぞれに指示に従った返信案を1〜2個生成してください。

        出力フォーマット (JSONのみ):
        {
          "summary": "指示にマッチした件数と動作の要約",
          "matched": [
            {
              "id": "メッセージid",
              "replies": [
                {"text": "返信案1", "tone": "instructed"},
                {"text": "返信案2", "tone": "instructed"}
              ]
            }
          ]
        }

        コードブロック不要、JSONのみ。
        """

        let userText = """
        指示: \(commandBarInput)

        未読メッセージ:
        \(String(data: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), encoding: .utf8) ?? "[]")
        """

        let payload: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 8192,
            "system": system,
            "messages": [["role": "user", "content": userText]]
        ]

        var req = URLRequest(url: URL(string: cfg.endpoint)!)
        req.httpMethod = "POST"
        req.setValue(cfg.authValue, forHTTPHeaderField: cfg.authHeader)
        if !cfg.isCloud { req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = root["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String
            else {
                commandBarResult = "⚠️ Claude応答が解析できません"
                return
            }
            var cleaned = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = cleaned.firstIndex(of: "{"), let e = cleaned.lastIndex(of: "}") {
                cleaned = String(cleaned[s...e])
            }
            guard let dict = try? JSONSerialization.jsonObject(with: cleaned.data(using: .utf8) ?? Data()) as? [String: Any] else {
                commandBarResult = "⚠️ JSON解析失敗"
                return
            }
            let summary = (dict["summary"] as? String) ?? ""
            let matched = (dict["matched"] as? [[String: Any]]) ?? []
            var count = 0
            for item in matched {
                guard let id = item["id"] as? String,
                      let repliesArr = item["replies"] as? [[String: String]] else { continue }
                if let m = messages.first(where: { $0.id == id }) {
                    // 既存drafts の先頭に instructed を追加
                    let newDrafts = repliesArr.compactMap { r -> ReplyDraft? in
                        guard let t = r["text"] else { return nil }
                        return ReplyDraft(text: t, tone: "instructed")
                    }
                    m.drafts.insert(contentsOf: newDrafts, at: 0)
                    count += 1
                }
            }
            store.persist(messages.filter { $0.status == .pending })
            commandBarResult = "✅ \(count)件に指示を適用: \(summary)"
            objectWillChange.send()
        } catch {
            commandBarResult = "⚠️ エラー: \(error.localizedDescription)"
        }
    }

    func skip(message: Message) {
        message.status = .skipped
        store.persist([message])
        objectWillChange.send()
    }

    // MARK: - Reply Planner (全連絡を俯瞰してAIが方針提案)

    func generatePlan() async {
        guard let cfg = llmConfig else {
            planError = "APIキーが設定されていません"
            return
        }
        let pending = messages.filter { $0.status == .pending }
        guard !pending.isEmpty else {
            planError = "未読メッセージがありません"
            return
        }
        planGenerating = true
        planError = nil
        defer { planGenerating = false }
        do {
            let plan = try await ReplyPlanner(config: cfg).plan(
                messages: pending,
                profileSnapshot: userProfile.profile
            )
            currentPlan = plan
            showPlanner = true
        } catch {
            planError = "プラン生成エラー: \(error.localizedDescription)"
        }
    }

    /// プランのグループ単位で一括実行
    func executePlanGroup(_ group: ReplyPlanner.Plan.Group) async {
        let targets = messages.filter { group.messageIds.contains($0.id) && $0.status == .pending }
        switch group.recommendedAction {
        case "reply":
            guard let suggestedText = group.suggestedReply, !suggestedText.isEmpty else { return }
            for m in targets {
                await send(message: m, draftIndex: 0, overrideText: suggestedText)
            }
        case "skip":
            for m in targets {
                m.status = .skipped
                store.persist([m])
            }
        case "later":
            let until = Date().addingTimeInterval(4*3600)
            for m in targets {
                m.status = .skipped
                m.snoozeUntil = until
                store.persist([m])
            }
        default:
            break  // customはユーザー個別判断
        }
        objectWillChange.send()
    }

    /// スヌーズ
    func snooze(message: Message, until: Date) {
        message.status = .skipped
        message.snoozeUntil = until
        store.persist([message])
        objectWillChange.send()
        // 簡易: タイマーは使わず、refresh時に復帰チェックするのが安全 (再起動後も動く)
    }

    /// snooze期限切れの復帰
    private func restoreSnoozedMessages() {
        let now = Date()
        for m in messages where m.status == .skipped && (m.snoozeUntil ?? .distantFuture) <= now {
            m.status = .pending
            m.snoozeUntil = nil
            store.persist([m])
        }
    }

    // MARK: - Background refresh

    func startBackgroundRefresh() {
        refreshTimer?.invalidate()
        // 10秒ごとに差分取得 (爆速化)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    // MARK: - Notifications

    private func postNotification(message: Message) async {
        let content = UNMutableNotificationContent()
        content.title = "\(message.service.displayName) · \(message.sender)"
        content.body = String(message.body.prefix(120))
        if let reason = message.reasonForPriority {
            content.subtitle = reason
        }
        content.sound = .default
        content.userInfo = ["messageId": message.id]

        let req = UNNotificationRequest(
            identifier: "trio_\(message.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Env fallback

    static func readEnv(key: String) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/workspace/trio/.env",
            "\(NSHomeDirectory())/.env"
        ]
        for path in candidates {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                    return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
        }
        return nil
    }
}
