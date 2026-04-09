import Foundation
import AppKit
import Vision
import CoreGraphics

/// 任意のmacOSアプリのウィンドウをOCRで読み取る汎用スクレーパー
/// APIがないサービス (Messenger, Discord, WhatsApp等) でも画面に表示されていれば取得できる
struct AppOCRScraper {

    /// サービスとbundle IDのマップ
    static let serviceBundles: [Service: [String]] = [
        .line: ["jp.naver.line.mac"],
        .slack: ["com.tinyspeck.slackmacgap", "com.Slack"],
        .chatwork: [
            "com.google.Chrome.app.mlnilknnlnjijlpcpdfpinknifpdbnmn",  // Chatwork PWA
        ],
        .discord: ["com.hnc.Discord"],
        .telegram: ["ru.keepcoder.Telegram", "org.telegram.desktop"],
        .messenger: ["com.facebook.archon", "com.facebook.Messenger"],
        .whatsapp: ["net.whatsapp.WhatsApp", "WhatsApp"],
        .teams: ["com.microsoft.teams", "com.microsoft.teams2"],
        .instagram: ["com.burbn.instagram"],
        .iMessage: ["com.apple.MobileSMS"],
    ]

    /// そのサービスのアプリが起動中か
    static func isAppRunning(for service: Service) -> Bool {
        guard let bundles = serviceBundles[service] else { return false }
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let bid = app.bundleIdentifier else { return false }
            return bundles.contains(bid)
        }
    }

    /// 該当サービスのアプリウィンドウをOCRしてMessage配列に変換
    static func fetch(for service: Service) async -> [Message] {
        guard let bundles = serviceBundles[service] else { return [] }
        // 該当するrunning appを見つける
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            guard let bid = $0.bundleIdentifier else { return false }
            return bundles.contains(bid)
        }) else {
            return []
        }

        // 画面収録権限チェック
        guard CGPreflightScreenCaptureAccess() else {
            tlog("[ocr-\(service.rawValue)] Screen Recording permission not granted")
            return []
        }

        // バックグラウンド取得: activate しない
        guard let img = captureWindow(pid: app.processIdentifier) else {
            tlog("[ocr-\(service.rawValue)] capture failed")
            return []
        }
        tlog("[ocr-\(service.rawValue)] captured \(img.width)x\(img.height)")
        let rows = ocr(img)
        tlog("[ocr-\(service.rawValue)] OCR rows: \(rows.count)")

        return parseGeneric(rows: rows, service: service)
    }

    private static func captureWindow(pid: Int32) -> CGImage? {
        let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        let windows = infos.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        }
        // タイトル有り、かつ最大サイズのウィンドウを選択
        let target = windows.max { a, b in
            let ah = (a[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0
            let bh = (b[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0
            return ah < bh
        }
        guard let wid = target?[kCGWindowNumber as String] as? CGWindowID else { return nil }
        return CGWindowListCreateImage(
            .null, .optionIncludingWindow, wid,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    struct Row {
        let text: String
        let x: CGFloat
        let y: CGFloat
        let confidence: Float
    }

    private static func ocr(_ image: CGImage) -> [Row] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja", "en"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { obs -> Row? in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let bb = obs.boundingBox
            return Row(
                text: cand.string,
                x: bb.minX,
                y: 1.0 - bb.maxY,
                confidence: cand.confidence
            )
        }.sorted { $0.y < $1.y }
    }

    /// 汎用的な解析: 縦方向で近接する行をグループ化してメッセージ化
    /// 完全ではないが、読めるテキストは全部Message化する (ユーザーに返信案を選んでもらうため)
    private static func parseGeneric(rows: [Row], service: Service) -> [Message] {
        // 信頼度 0.3 以上、2文字以上のテキストだけ
        let filtered = rows.filter { $0.confidence > 0.3 && $0.text.count >= 2 }
        guard !filtered.isEmpty else { return [] }

        // Y座標で近接する行をグループ化 (threshold 0.035)
        var groups: [[Row]] = []
        var current: [Row] = []
        var lastY: CGFloat = -1
        let threshold: CGFloat = 0.035

        for r in filtered {
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
        let today = Date()
        for (idx, group) in groups.enumerated() {
            let combined = group.map { $0.text }.joined(separator: " ")
            // 短すぎるか記号だけのものは除外
            let meaningful = combined.trimmingCharacters(in: .whitespaces)
            guard meaningful.count >= 5 else { continue }
            guard meaningful.contains(where: { $0.isLetter }) else { continue }

            messages.append(Message(
                id: "\(service.rawValue)_ocr_\(idx)_\(meaningful.hashValue)",
                service: service,
                serviceIdentifier: serviceBundles[service]?.first,
                sender: service.displayName,
                threadId: nil,
                body: meaningful,
                receivedAt: today
            ))
        }
        // 上限: 30件
        return Array(messages.prefix(30))
    }
}
