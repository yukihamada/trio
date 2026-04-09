#!/usr/bin/env swift
// OCR精度向上版: ScreenCaptureKit + Vision + 構造化
import Cocoa
import Vision
import ScreenCaptureKit
import CoreGraphics

// MARK: - Models

struct LineRow {
    let text: String
    let x: CGFloat       // 0.0-1.0
    let y: CGFloat       // 0.0-1.0 (upper-left origin で正規化)
    let w: CGFloat
    let h: CGFloat
    let confidence: Float
}

struct LineChat {
    let sender: String
    let preview: String
    let timeLabel: String?
}

struct LineMessage {
    let sender: String?
    let body: String
    let time: String?
}

// MARK: - Capture via ScreenCaptureKit

func captureLINEWindow() -> CGImage? {
    guard let pid = NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "jp.naver.line.mac" })?.processIdentifier
    else {
        print("❌ LINE not running"); return nil
    }
    let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    let lineWindows = infos.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid &&
        ($0[kCGWindowLayer as String] as? Int) == 0
    }
    let target = lineWindows.first(where: {
        let n = $0[kCGWindowName as String] as? String ?? ""
        return !n.isEmpty
    }) ?? lineWindows.first
    guard let wid = target?[kCGWindowNumber as String] as? CGWindowID else {
        print("❌ no LINE window"); return nil
    }
    return CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .bestResolution])
}

// MARK: - OCR

func ocr(_ cgImage: CGImage) -> [LineRow] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ["ja", "en"]
    req.usesLanguageCorrection = true
    req.minimumTextHeight = 0.005

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([req]) } catch {
        print("❌ OCR: \(error)"); return []
    }
    let results = req.results ?? []

    var rows: [LineRow] = []
    for obs in results {
        guard let cand = obs.topCandidates(1).first else { continue }
        let bb = obs.boundingBox  // VisionはY軸が下基準なので反転
        rows.append(LineRow(
            text: cand.string,
            x: bb.minX,
            y: 1.0 - bb.maxY,   // 上が0になるよう変換
            w: bb.width,
            h: bb.height,
            confidence: cand.confidence
        ))
    }
    return rows.sorted { $0.y < $1.y }
}

// MARK: - 構造化: チャットリスト + メッセージパネルに分離

struct LineLayout {
    let chatListXMax: CGFloat = 0.30   // 左カラム幅 ~30%
    let messagePanelXMin: CGFloat = 0.32

    func parse(rows: [LineRow]) -> (chats: [LineChat], messages: [LineMessage]) {
        let leftRows = rows.filter { $0.x < chatListXMax && $0.confidence > 0.3 }
        let rightRows = rows.filter { $0.x >= messagePanelXMin && $0.confidence > 0.3 }

        let chats = parseChatList(leftRows)
        let messages = parseMessagePanel(rightRows)
        return (chats, messages)
    }

    /// 左カラム: 「送信者名 / プレビュー / 時刻」が縦に並ぶ
    /// Y座標が近い(±0.02)行を1チャットエントリとしてグループ化
    private func parseChatList(_ rows: [LineRow]) -> [LineChat] {
        guard !rows.isEmpty else { return [] }
        let sorted = rows.sorted { $0.y < $1.y }
        var groups: [[LineRow]] = []
        var current: [LineRow] = []
        var lastY: CGFloat = -1
        let threshold: CGFloat = 0.035  // 1チャットエントリの縦幅

        for r in sorted {
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

        return groups.compactMap { group in
            // 最上行が送信者名、続きはプレビュー、末尾(右上)は時刻
            let sortedY = group.sorted { $0.y < $1.y }
            guard let sender = sortedY.first?.text, sender.count > 1 else { return nil }
            let preview = sortedY.dropFirst().map { $0.text }.joined(separator: " ")
            // 時刻ラベル抽出 (「昨日」「午前」「数字:数字」等)
            let timeLabel = group.first(where: {
                $0.text.contains("昨日") || $0.text.contains("午前") || $0.text.contains("午後") || $0.text.range(of: #"\d+:\d+"#, options: .regularExpression) != nil
            })?.text
            return LineChat(sender: sender, preview: preview, timeLabel: timeLabel)
        }
    }

    /// 右カラム: 開いてるチャットのメッセージ列
    /// 連続行をメッセージにグループ化、時刻ラベル(午前9:44 等)で区切る
    private func parseMessagePanel(_ rows: [LineRow]) -> [LineMessage] {
        guard !rows.isEmpty else { return [] }
        let sorted = rows.sorted { $0.y < $1.y }
        var messages: [LineMessage] = []
        var buffer: [String] = []
        var pendingSender: String? = nil
        var pendingTime: String? = nil

        let timePattern = #"^(午前|午後|AM|PM)?\s?\d{1,2}[:：]\d{2}$"#

        for r in sorted {
            let t = r.text.trimmingCharacters(in: .whitespaces)
            // 時刻だけの行
            if t.range(of: timePattern, options: .regularExpression) != nil {
                if !buffer.isEmpty {
                    messages.append(LineMessage(
                        sender: pendingSender,
                        body: buffer.joined(separator: " "),
                        time: pendingTime
                    ))
                    buffer = []
                }
                pendingTime = t
                continue
            }
            // ヘッダーの「ウィンドウタイトル」「<Enabler> Atami Admin (6)」などはスキップ
            if r.y < 0.06 { continue }
            // 入力エリア
            if t.contains("メッセージを入力") { continue }
            // 短すぎる/記号
            if t.count < 2 { continue }

            buffer.append(t)
        }
        if !buffer.isEmpty {
            messages.append(LineMessage(sender: pendingSender, body: buffer.joined(separator: " "), time: pendingTime))
        }
        return messages
    }
}

// MARK: - Main

do {
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "jp.naver.line.mac" }) {
        app.activate(options: [])
        Thread.sleep(forTimeInterval: 0.8)
    }

    guard let img = captureLINEWindow() else {
        print("❌ capture failed"); exit(1)
    }
        print("✅ captured: \(img.width)×\(img.height) (Retina)")

        // 保存
        let url = URL(fileURLWithPath: "/tmp/line_v2.png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
            print("✅ saved /tmp/line_v2.png")
        }

        let rows = ocr(img)
        print("✅ OCR行数: \(rows.count)")

    let layout = LineLayout()
    let (chats, messages) = layout.parse(rows: rows)

    print("\n=== 📋 チャットリスト (\(chats.count)件) ===")
    for (i, c) in chats.enumerated() {
        print("[\(i)] 👤 \(c.sender)")
        if !c.preview.isEmpty {
            print("    💬 \(c.preview.prefix(80))")
        }
        if let t = c.timeLabel { print("    🕐 \(t)") }
    }

    print("\n=== 💌 開いているチャットのメッセージ (\(messages.count)件) ===")
    for (i, m) in messages.enumerated() {
        print("[\(i)] \(m.body.prefix(120))")
        if let t = m.time { print("    🕐 \(t)") }
    }
}
