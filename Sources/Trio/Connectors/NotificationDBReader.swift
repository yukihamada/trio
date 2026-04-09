import Foundation

/// macOSの通知センターDBを読み取り、LINE/Slack/Chatwork等の通知をMessageに変換。
/// DBパス: $DARWIN_USER_DIR/0/com.apple.notificationcenter/db2/db
/// 要: Full Disk Access権限
struct NotificationDBReader {

    /// bundle identifier → Service
    static let bundleMap: [String: Service] = [
        "jp.naver.line.mac": .line,
        "com.tinyspeck.slackmacgap": .slack,
        "com.Slack": .slack,
        "com.apple.mobilesms": .iMessage,
        "com.apple.mail": .mail,
        "com.hnc.Discord": .discord,
        "com.apple.ical": .calendar,
        "com.apple.reminders": .reminders,
        "com.apple.facetime": .facetime,
        "com.apple.FaceTime": .facetime,
        "ru.keepcoder.Telegram": .telegram,
        "org.telegram.desktop": .telegram,
        "com.facebook.archon": .messenger,
        "com.facebook.Messenger": .messenger,
        "WhatsApp": .whatsapp,
        "net.whatsapp.WhatsApp": .whatsapp,
        "com.microsoft.teams": .teams,
        "com.microsoft.teams2": .teams,
        "com.microsoft.outlook": .outlook,
        "com.google.Chrome.app.mlnilknnlnjijlpcpdfpinknifpdbnmn": .chatwork,  // Chatwork PWA
        "com.burbn.instagram": .instagram,
    ]

    /// 除外する通知元 (ユーザーの自作アプリ、システム通知、広告系)
    static let blockedIdentifiers: Set<String> = [
        "com.yuki.koe",
    ]

    static let blockedPrefixes: [String] = [
        "_system_center_:",
        "com.apple.controlcenter",
        "com.apple.screentimenotifications",
        "com.apple.passbook",
        "com.apple.appstore",
        "com.apple.applemediaservices",
        "com.apple.gamecenter",
        "com.apple.identityservicesd",
        "com.apple.home",
        "com.apple.cmio.continuitycamera",
        "com.apple.findmy",
        "com.apple.replaykit",
        "com.apple.mdmclient",
        "com.apple.migrationhelper",
        "com.apple.followup",
        "com.apple.security",
        "com.apple.sharingd",
        "com.apple.wifi",
        "com.apple.accountsd",
        "com.apple.tmhelperagent",
        "com.apple.bluetooth",
        "com.apple.askpermissiond",
        "com.apple.appleaccount",
    ]

    static func isBlocked(identifier: String) -> Bool {
        if blockedIdentifiers.contains(identifier) { return true }
        return blockedPrefixes.contains { identifier.hasPrefix($0) }
    }

    /// 名前・URLから推測する追加分類
    static func guessService(identifier: String, title: String, body: String) -> Service {
        let idLower = identifier.lowercased()
        let titleLower = title.lowercased()
        let bodyLower = body.lowercased()
        let combined = "\(idLower) \(titleLower) \(bodyLower)"

        if combined.contains("slack") { return .slack }
        if combined.contains("chatwork") { return .chatwork }
        if combined.contains("discord") { return .discord }
        if combined.contains("telegram") { return .telegram }
        if combined.contains("messenger") || combined.contains("facebook") { return .messenger }
        if combined.contains("whatsapp") { return .whatsapp }
        if combined.contains("teams") { return .teams }
        if combined.contains("gmail") || combined.contains("google mail") { return .gmail }
        if combined.contains("outlook") { return .outlook }
        if combined.contains("instagram") { return .instagram }
        if combined.contains("line") { return .line }
        if combined.contains("mail") { return .mail }
        return .unknown
    }

    static func dbPath() -> String? {
        // getconf DARWIN_USER_DIR を実行して動的に解決
        let task = Process()
        task.launchPath = "/usr/bin/getconf"
        task.arguments = ["DARWIN_USER_DIR"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let dir = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty else {
                return nil
            }
            // getconfは末尾に"0/"を含むパスを返すので、そのまま直接続ける
            let base = dir.hasSuffix("/") ? dir : "\(dir)/"
            return "\(base)com.apple.notificationcenter/db2/db"
        } catch {
            return nil
        }
    }

    /// 実際にDBファイルをopenしてTCCの可否を判定
    static func isFDAMissing() -> Bool {
        guard let path = dbPath() else { return false }
        if !FileManager.default.fileExists(atPath: path) { return false }
        // 直接open(2)で試す。TCCで拒否されるとENOENT相当のエラーか実データ0
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            return true  // EPERM等 → FDA未付与
        }
        // 先頭16バイト読んでSQLite magicを確認
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, 16)
        close(fd)
        if n <= 0 { return true }
        // SQLite format 3 magic
        let magic = "SQLite format 3"
        let got = String(bytes: buf.prefix(magic.count), encoding: .utf8) ?? ""
        return got != magic
    }

    /// 過去N時間以内の通知を読み取る。sqlite3 CLIを使い、各レコードをbplistとしてデコード。
    static func fetchRecent(hours: Double = 24) -> [Message] {
        let resolved = dbPath() ?? "nil"
        let exists = dbPath().map { FileManager.default.fileExists(atPath: $0) } ?? false
        let debug = "[\(Date())] [notif] dbPath='\(resolved)' exists=\(exists)\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/trio.log")) {
            h.seekToEndOfFile()
            h.write(debug.data(using: .utf8)!)
            try? h.close()
        }
        guard let path = dbPath(), FileManager.default.fileExists(atPath: path) else {
            return []
        }

        // Core Data epoch (2001-01-01) → Unix epoch変換: +978307200
        let sinceMacTime = Date().addingTimeInterval(-hours * 3600).timeIntervalSinceReferenceDate

        let query = """
        SELECT a.identifier, r.rec_id, r.delivered_date, r.data
        FROM record r JOIN app a ON r.app_id = a.app_id
        WHERE r.delivered_date > \(sinceMacTime)
        ORDER BY r.delivered_date DESC;
        """

        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [path, "-cmd", ".mode list", "-cmd", ".separator |", query]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("[NotificationDBReader] sqlite3 failed: \(error)")
            return []
        }

        _ = pipe.fileHandleForReading.readDataToEndOfFile()
        // bplistバイナリ文字化けを避けるため writefile() でテンポラリ展開する方式
        return fetchViaTempfiles(path: path, sinceMacTime: sinceMacTime)
    }

    /// SQLite の writefile() でbplistをtmpに書き出し、plutilでXMLに変換してパース。
    private static func fetchViaTempfiles(path: String, sinceMacTime: TimeInterval) -> [Message] {
        let tmpDir = NSTemporaryDirectory() + "trio_notif_\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // デバッグ: まずCOUNTしてレコード数を確認
        let countTask = Process()
        countTask.launchPath = "/usr/bin/sqlite3"
        countTask.arguments = [path, "SELECT COUNT(*) FROM record;"]
        let countOut = Pipe()
        let countErr = Pipe()
        countTask.standardOutput = countOut
        countTask.standardError = countErr
        do {
            try countTask.run()
            countTask.waitUntilExit()
        } catch {
            try? "[notif] sqlite3 exec failed: \(error)\n".data(using: .utf8)?.write(
                to: URL(fileURLWithPath: "/tmp/trio.log"), options: []
            )
        }
        let countStr = String(data: countOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: countErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let logLine = "[\(Date())] [notif] COUNT result: '\(countStr.trimmingCharacters(in: .whitespacesAndNewlines))' stderr: '\(errStr.trimmingCharacters(in: .whitespacesAndNewlines))'\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/trio.log")) {
            h.seekToEndOfFile()
            h.write(logLine.data(using: .utf8)!)
            try? h.close()
        }

        // 各レコードを個別ファイルに書き出す
        let dumpSQL = """
        SELECT writefile('\(tmpDir)' || r.rec_id || '_' || a.identifier || '.bplist', r.data)
        FROM record r JOIN app a ON r.app_id = a.app_id
        WHERE r.delivered_date > \(sinceMacTime);
        """

        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [path, dumpSQL]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmpDir) else {
            return []
        }

        var messages: [Message] = []
        for file in files where file.hasSuffix(".bplist") {
            let full = tmpDir + file
            // ファイル名: "<rec_id>_<identifier>.bplist"
            let base = (file as NSString).deletingPathExtension
            let parts = base.split(separator: "_", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let recId = parts[0]
            let identifier = parts[1]

            guard let msg = parseBplist(path: full, identifier: identifier, recId: recId) else {
                continue
            }
            messages.append(msg)
        }
        return messages
    }

    private static func parseBplist(path: String, identifier: String, recId: String) -> Message? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        guard let req = plist["req"] as? [String: Any] else { return nil }
        let titl = (req["titl"] as? String) ?? ""
        let body = (req["body"] as? String) ?? ""
        let thre = req["thre"] as? String
        let dateVal = req["date"] as? Double ?? (plist["date"] as? Double) ?? 0

        guard !body.isEmpty else { return nil }

        // 除外するアプリ
        if Self.isBlocked(identifier: identifier) { return nil }

        let service = bundleMap[identifier] ?? Self.guessService(identifier: identifier, title: titl, body: body)
        let date = Date(timeIntervalSinceReferenceDate: dateVal)

        return Message(
            id: "\(identifier)_\(recId)",
            service: service,
            serviceIdentifier: identifier,
            sender: titl.isEmpty ? identifier : titl,
            threadId: thre,
            body: body,
            receivedAt: date
        )
    }
}
