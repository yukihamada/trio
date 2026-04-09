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
            try await sendViaLINE(chatName: message.threadId ?? message.sender, text: replyText)

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

    /// LINE 自動送信 (天才的方法):
    /// 1. トーク検索で相手を見つける
    /// 2. ウィンドウメニューで確実にチャット選択
    /// 3. cliclick で入力欄クリック (AX不要)
    /// 4. ペースト + Enter
    private func sendViaLINE(chatName: String, text: String) async throws {
        guard let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "jp.naver.line.mac") else {
            throw NSError(domain: "Dispatcher", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "LINE.app not found"])
        }

        // Step 1: LINE起動 + トーク検索で相手のチャットを開く
        let searchName = chatName
            .replacingOccurrences(of: "LINE · ", with: "")
            .replacingOccurrences(of: "LINE·", with: "")
            .components(separatedBy: " ").first ?? chatName
        let searchScript = """
        tell application "LINE" to activate
        delay 0.8
        tell application "System Events"
          tell process "LINE"
            set frontmost to true
            delay 0.3
            keystroke "2" using {command down}
            delay 0.5
          end tell
        end tell
        """
        try runOSA(searchScript)

        // 検索バーで相手を検索
        let task1 = Process()
        task1.launchPath = "/opt/homebrew/bin/cliclick"
        task1.arguments = ["c:120,75"]
        try task1.run()
        task1.waitUntilExit()
        try await Task.sleep(nanoseconds: 500_000_000)

        let typeScript = """
        tell application "System Events"
          keystroke "a" using {command down}
          delay 0.1
          key code 51
          delay 0.1
          keystroke "\(searchName)"
          delay 1.5
          key code 125
          delay 0.3
          key code 36
          delay 1.5
        end tell
        """
        try runOSA(typeScript)

        // Step 2: クリップボードにメッセージセット
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Step 3: cliclick で入力欄クリック
        let task2 = Process()
        task2.launchPath = "/opt/homebrew/bin/cliclick"
        task2.arguments = ["c:600,870"]
        try task2.run()
        task2.waitUntilExit()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Step 4: ペースト + 送信
        let sendScript = """
        tell application "System Events"
          keystroke "v" using {command down}
          delay 0.8
          key code 36
        end tell
        """
        try runOSA(sendScript)
    }

    // (旧LINE送信メソッド削除済み — 天才的方法に統合)

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
