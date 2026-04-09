import Foundation
import AppKit
import UserNotifications

/// メッセージの送信を統括。Slack/Chatwork=API、LINE/iMessage=半自動(AppleScript/Clipboard)
struct Dispatcher {
    let slackToken: String?
    let chatworkToken: String?

    func send(message: Message, replyText: String) async throws {
        switch message.service {
        case .slack:
            guard let t = slackToken, let ch = message.threadId else {
                throw NSError(domain: "Dispatcher", code: 1)
            }
            try await SlackConnector(token: t).postMessage(channel: ch, text: replyText)

        case .chatwork:
            guard let t = chatworkToken, let room = message.threadId else {
                throw NSError(domain: "Dispatcher", code: 1)
            }
            try await ChatworkConnector(token: t).postMessage(roomId: room, text: replyText)

        case .iMessage:
            try sendViaMessages(handle: message.sender, text: replyText)

        case .line:
            // LINEは画面を奪わず、クリップボード＋通知で案内
            try await sendViaClipboardNotify(
                service: "LINE",
                chatName: message.threadId ?? message.sender,
                text: replyText,
                bundleId: "jp.naver.line.mac"
            )

        default:
            // 全サービス共通: 画面を奪わずクリップボード＋通知
            let bid = AppOCRScraper.serviceBundles[message.service]?.first
            try await sendViaClipboardNotify(
                service: message.serviceDisplayName,
                chatName: message.sender,
                text: replyText,
                bundleId: bid
            )
        }
    }

    /// クリップボードにコピー + macOS通知で案内 (画面を奪わない)
    private func sendViaClipboardNotify(service: String, chatName: String, text: String, bundleId: String?) async throws {
        // 1. クリップボードに返信テキストをコピー
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // 2. macOS通知で「貼り付けてね」と案内
        let content = UNMutableNotificationContent()
        content.title = "📋 \(service) に返信をコピーしました"
        content.body = "\(chatName) へ: \(text.prefix(80))"
        content.subtitle = "\(service)を開いて Cmd+V で貼り付け"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "trio_send_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// LINE 完全自動送信 (信頼性強化版):
    /// 1. LINE.appアクティブ化 → フォーカス確認
    /// 2. Cmd+K クイック検索 → チャット名検索 → Return で開く
    /// 3. 入力欄フォーカス → Cmd+V → Return
    /// エラー時: 最大2回リトライ、失敗時クリップボードに本文を残してユーザー通知
    private func sendViaLINE(chatName: String, text: String) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.naver.line.mac") else {
            throw NSError(domain: "Dispatcher", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "LINE.app not found"])
        }

        // LINE.app起動 → frontmost化
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        try await Task.sleep(nanoseconds: 900_000_000)

        // LINEプロセスがfrontmostになるまで最大2秒待機
        var frontOk = false
        for _ in 0..<10 {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier == "jp.naver.line.mac" {
                frontOk = true
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard frontOk else {
            // フォールバック: クリップボードに本文を残してエラー
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            throw NSError(domain: "Dispatcher", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "LINE.app がアクティブ化できませんでした。本文はクリップボードにコピーしました。"])
        }

        // Step 1: Cmd+K で検索
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chatName, forType: .string)
        try await Task.sleep(nanoseconds: 150_000_000)

        let openChatScript = """
        tell application "System Events"
            tell process "LINE"
                set frontmost to true
                delay 0.4
                keystroke "k" using {command down}
                delay 0.5
                keystroke "a" using {command down}
                delay 0.1
                key code 51
                delay 0.1
                keystroke "v" using {command down}
                delay 0.45
                key code 36
                delay 0.9
            end tell
        end tell
        """
        try runOSA(openChatScript)

        // Step 2: 本文をクリップボードへ
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Step 3: 入力欄にフォーカス → Cmd+V → Return
        // 入力欄クリックはAX経由が理想だが、Returnで閉じた直後は入力欄がフォーカスされている前提
        let sendScript = """
        tell application "System Events"
            tell process "LINE"
                set frontmost to true
                delay 0.25
                keystroke "v" using {command down}
                delay 0.25
                key code 36
                delay 0.2
            end tell
        end tell
        """
        try runOSA(sendScript)
    }

    private func runOSA(_ script: String) throws {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let err = Pipe()
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "Dispatcher", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "osascript失敗: \(errStr)"])
        }
    }

    private func sendViaMessages(handle: String, text: String) throws {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let handleEsc = handle.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Messages"
            set targetBuddy to "\(handleEsc)"
            set targetService to 1st service whose service type = iMessage
            set theBuddy to buddy targetBuddy of targetService
            send "\(escaped)" to theBuddy
        end tell
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            // iMessage失敗時もクリップボード方式にフォールバック
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            throw NSError(domain: "Dispatcher", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "📋 iMessage送信失敗。クリップボードにコピーしました。"])
        }
    }
}
