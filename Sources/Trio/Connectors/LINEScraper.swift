import Foundation
import AppKit
import Vision
import CoreGraphics

/// LINE.app のウィンドウをCGWindowListでキャプチャしVision OCRで構造化。
/// 唯一のLINEメッセージ取得手段 (公式APIなし、ローカルDB暗号化、AX非対応)
struct LINEScraper {

    struct OCRRow {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let confidence: Float
    }

    static let bundleId = "jp.naver.line.mac"

    static func isAvailable() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    /// 画面収録権限の確認 & 未付与時はmacOSプロンプトを発火
    static func ensureScreenCapturePermission() {
        if !CGPreflightScreenCaptureAccess() {
            // これがシステムプロンプトを発火させる
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// 全チャット走査モード: 矢印キーで各チャットを順に開いてOCR蓄積
    /// 数十秒かかる。完了までユーザーは待つ必要あり
    static func fetchAll(maxIterations: Int = 40) async -> [Message] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return []
        }
        ensureScreenCapturePermission()
        guard CGPreflightScreenCaptureAccess() else {
            return []
        }
        app.activate(options: [])
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Step 1: トーク一覧に切り替え (Cmd+2)
        runKeyScript("""
        tell application "System Events"
            tell process "LINE"
                set frontmost to true
                delay 0.3
                keystroke "2" using {command down}
                delay 0.4
            end tell
        end tell
        """)

        // Step 2: 一番上のチャットを選択
        runKeyScript("""
        tell application "System Events"
            tell process "LINE"
                -- チャット一覧にフォーカス → 先頭へ
                key code 115  -- Home
                delay 0.2
            end tell
        end tell
        """)

        var allMessages: [Message] = []
        var seenKey: Set<String> = []
        var idCounter = 0

        for iter in 0..<maxIterations {
            // キャプチャ & OCR
            guard let img = captureWindow(pid: app.processIdentifier) else { break }
            let rows = ocr(img)
            let parsed = parse(rows: rows)

            for m in parsed {
                let key = "\(m.sender)|\(m.body.prefix(50))"
                if !seenKey.contains(key) {
                    seenKey.insert(key)
                    idCounter += 1
                    let unique = Message(
                        id: "line_scan_\(idCounter)_\(m.sender.hashValue)",
                        service: .line,
                        serviceIdentifier: "jp.naver.line.mac",
                        sender: m.sender,
                        threadId: m.sender,
                        body: m.body,
                        receivedAt: Date()
                    )
                    allMessages.append(unique)
                }
            }

            // 次のチャットへ (下矢印)
            runKeyScript("""
            tell application "System Events"
                tell process "LINE"
                    key code 125
                    delay 0.25
                end tell
            end tell
            """)

            // 4回に1回progressログ
            if iter % 4 == 0 {
                tlog("[line-scan] iter \(iter): \(allMessages.count) unique messages so far")
            }
        }
        tlog("[line-scan] completed: \(allMessages.count) total")
        return allMessages
    }

    private static func runKeyScript(_ script: String) {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
        task.waitUntilExit()
    }

    /// LINE.appを前面化 → キャプチャ → OCR → Message配列に変換
    static func fetch() async -> [Message] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            tlog("[line] LINE.app not running")
            return []
        }
        // 権限チェック+プロンプト発火
        ensureScreenCapturePermission()
        guard CGPreflightScreenCaptureAccess() else {
            tlog("[line] Screen Recording permission not granted yet")
            return []
        }

        // バックグラウンド取得: activate しない (フォーカスを奪わない)
        guard let img = captureWindow(pid: app.processIdentifier) else {
            tlog("[line] capture failed (window not found?)")
            return []
        }
        tlog("[line] captured \(img.width)x\(img.height)")
        let rows = ocr(img)
        tlog("[line] OCR rows: \(rows.count)")
        let msgs = parse(rows: rows)
        tlog("[line] parsed messages: \(msgs.count)")
        if msgs.isEmpty && !rows.isEmpty {
            let sample = rows.prefix(5).map { "[\($0.text.prefix(20)) x=\(String(format:"%.2f",$0.x)) y=\(String(format:"%.2f",$0.y))]" }.joined(separator: " ")
            tlog("[line] sample rows: \(sample)")
        }
        return msgs
    }

    private static func captureWindow(pid: Int32) -> CGImage? {
        let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let lineWindows = infos.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
        let target = lineWindows.first(where: {
            let n = $0[kCGWindowName as String] as? String ?? ""
            return !n.isEmpty
        }) ?? lineWindows.first
        guard let wid = target?[kCGWindowNumber as String] as? CGWindowID else { return nil }
        return CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                        [.boundsIgnoreFraming, .bestResolution])
    }

    private static func ocr(_ image: CGImage) -> [OCRRow] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja", "en"]
        req.usesLanguageCorrection = true
        req.minimumTextHeight = 0.005

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch { return [] }

        return (req.results ?? []).compactMap { obs -> OCRRow? in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let bb = obs.boundingBox
            return OCRRow(
                text: cand.string,
                x: bb.minX,
                y: 1.0 - bb.maxY,
                confidence: cand.confidence
            )
        }.sorted { $0.y < $1.y }
    }

    /// UIノイズワードブラックリスト (OCRで拾われるヘッダーやラベル)
    private static let noiseWords: Set<String> = [
        "すべて", "友だち", "グループ", "オープンチャット", "公式アカウント",
        "検索", "トークルームとメッセージ検索", "メッセージを入力",
        "ホーム", "トーク", "ニュース", "ウォレット",
        "LINE", "LINE VOOM",
        "昨日", "今日", "先週",
        "昨", "●", "○", "◎", "口", "目"
    ]

    /// ヘッダー/入力欄のノイズを除去
    private static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.count < 2 { return true }
        if noiseWords.contains(t) { return true }
        // 数字のみ (Y: 12:34 みたいな時刻は残す)
        if t.allSatisfy({ $0.isNumber }) && t.count < 4 { return true }
        // 記号のみ
        if t.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
        return false
    }

    /// 左カラム(チャットリスト) と 右カラム(メッセージ本文) を分離してMessageに変換。
    /// LINEのレイアウト: タブ(0-0.05) / チャットリスト(0.05-0.30) / メッセージパネル(0.30-1.0)
    private static func parse(rows: [OCRRow]) -> [Message] {
        // 左カラム: x < 0.35, 信頼度 >= 0.25, ヘッダー/フッターは除外
        let chatListRows = rows.filter {
            $0.x > 0.03 && $0.x < 0.36 &&
            $0.y > 0.06 && $0.y < 0.95 &&
            $0.confidence >= 0.25 &&
            !isNoise($0.text)
        }

        // Y座標が近い行を1チャットエントリにグループ化
        var groups: [[OCRRow]] = []
        var current: [OCRRow] = []
        var lastY: CGFloat = -1
        let threshold: CGFloat = 0.05

        for r in chatListRows.sorted(by: { $0.y < $1.y }) {
            if lastY < 0 || abs(r.y - lastY) < threshold {
                current.append(r)
                lastY = r.y
            } else {
                if !current.isEmpty { groups.append(current) }
                current = [r]
                lastY = r.y
            }
        }
        if !current.isEmpty { groups.append(current) }

        var messages: [Message] = []
        for (idx, group) in groups.enumerated() {
            // Y座標でソート、最初の行を送信者名として採用
            let sorted = group.sorted { $0.y < $1.y }
            guard let first = sorted.first else { continue }
            let sender = first.text.trimmingCharacters(in: .whitespaces)
            guard sender.count >= 2 else { continue }

            // 送信者名に数字だけ(0570-XXX系スパム)や記号だけの行は除外
            let letterCount = sender.filter { $0.isLetter }.count
            if letterCount < 1 { continue }

            let preview = sorted.dropFirst()
                .map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !isNoise($0) && !$0.isEmpty }
                .joined(separator: " ")
            guard !preview.isEmpty else { continue }

            messages.append(Message(
                id: "line_ocr_\(sender)_\(idx)",
                service: .line,
                sender: sender,
                threadId: sender,
                body: preview,
                receivedAt: Date()
            ))
        }
        return messages
    }
}
