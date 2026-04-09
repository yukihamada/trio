import Foundation
import AppKit
import Contacts

/// ユーザー自身のプロファイル
/// - macOSから自動取得 (名前/メール)
/// - 送信履歴から文体を学習
/// - 連絡先との関係性を蓄積
@MainActor
final class UserProfile: ObservableObject {
    static let shared = UserProfile()

    struct Profile: Codable {
        var fullName: String = ""
        var email: String = ""
        var bio: String = ""               // 自分のプロフィール (手動設定可)
        var signature: String = ""         // 署名 (手動設定可)

        // 文体サンプル (過去に送信したメッセージから最大20件)
        var writingSamples: [WritingSample] = []

        // 連絡先ごとのメタデータ
        var contacts: [String: ContactMeta] = [:]

        // 統計
        var totalSent: Int = 0
        var lastUpdated: Date = .now
    }

    struct WritingSample: Codable {
        var text: String
        var tone: String
        var recipient: String
        var incomingBody: String? = nil   // 返信元のメッセージ本文 (Few-shot用)
        var service: String? = nil
        var timestamp: Date
    }

    struct ContactMeta: Codable {
        var displayName: String          // 表示名
        var relationship: String = ""    // 家族/友人/同僚/取引先/不明
        var preferredTone: String = ""   // このコンタクトに対していつも使うtone
        var totalExchanges: Int = 0      // やり取り回数
        var lastInteraction: Date?
        var notes: String = ""           // 任意メモ
    }

    @Published var profile: Profile
    private let fileURL: URL

    init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Trio", isDirectory: true)
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Trio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profile.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.trio.decode(Profile.self, from: data) {
            self.profile = decoded
        } else {
            var p = Profile()
            p.fullName = NSFullUserName()  // これはblockingしない
            self.profile = p
            save()
        }
        // Contactsアクセスは非同期で (blockingしないよう)
        Task { @MainActor in
            if self.profile.email.isEmpty, let email = await Self.detectEmailAsync() {
                self.profile.email = email
                self.save()
            }
        }
    }

    func save() {
        profile.lastUpdated = .now
        if let data = try? JSONEncoder.trio.encode(profile) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    // MARK: - 送信記録

    /// 送信したメッセージを文体サンプルとして記録
    func recordSent(text: String, tone: String, recipient: String, incomingBody: String? = nil, service: String? = nil) {
        let sample = WritingSample(
            text: text,
            tone: tone,
            recipient: recipient,
            incomingBody: incomingBody,
            service: service,
            timestamp: .now
        )
        profile.writingSamples.insert(sample, at: 0)
        if profile.writingSamples.count > 50 {
            profile.writingSamples = Array(profile.writingSamples.prefix(50))
        }
        profile.totalSent += 1

        // コンタクトの統計も更新
        var meta = profile.contacts[recipient] ?? ContactMeta(displayName: recipient)
        meta.totalExchanges += 1
        meta.lastInteraction = .now
        // 繰り返し同じtoneを使うならpreferredToneに反映
        let recentSamples = profile.writingSamples.filter { $0.recipient == recipient }
        let toneFreq = Dictionary(grouping: recentSamples, by: { $0.tone })
            .mapValues { $0.count }
        if let mostCommon = toneFreq.max(by: { $0.value < $1.value }) {
            meta.preferredTone = mostCommon.key
        }
        profile.contacts[recipient] = meta

        save()
    }

    /// 受信メッセージから相手を学習
    func observeIncoming(sender: String, service: String) {
        var meta = profile.contacts[sender] ?? ContactMeta(displayName: sender)
        if meta.displayName.isEmpty { meta.displayName = sender }
        profile.contacts[sender] = meta
        save()
    }

    // MARK: - LLMコンテキスト生成

    /// ClaudeのプロンプトにinjectするYou/User情報
    func promptContext(for sender: String) -> String {
        var lines: [String] = []
        lines.append("【ユーザー(返信者)の情報】")
        if !profile.fullName.isEmpty { lines.append("名前: \(profile.fullName)") }
        if !profile.email.isEmpty { lines.append("メール: \(profile.email)") }
        if !profile.bio.isEmpty { lines.append("自己紹介: \(profile.bio)") }

        if !profile.writingSamples.isEmpty {
            lines.append("【ユーザーの文体サンプル(過去の送信)】")
            for s in profile.writingSamples.prefix(5) {
                lines.append("- [\(s.tone)] \(s.text)")
            }
        }

        if let meta = profile.contacts[sender] {
            lines.append("【相手 (\(sender)) との関係】")
            if !meta.relationship.isEmpty {
                lines.append("関係: \(meta.relationship)")
            }
            if meta.totalExchanges > 0 {
                lines.append("過去のやり取り: \(meta.totalExchanges)回")
            }
            if !meta.preferredTone.isEmpty {
                lines.append("よく使うtone: \(meta.preferredTone)")
            }
            if !meta.notes.isEmpty {
                lines.append("メモ: \(meta.notes)")
            }
        }

        if !profile.signature.isEmpty {
            lines.append("【署名】\(profile.signature)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Auto-detect

    private static func detectEmailAsync() async -> String? {
        // 許可済みの場合のみContactsにアクセス (認可ダイアログで固まらないよう)
        let status = CNContactStore.authorizationStatus(for: .contacts)
        guard status == .authorized else { return nil }
        let store = CNContactStore()
        let keys = [CNContactEmailAddressesKey as CNKeyDescriptor]
        if let me = try? store.unifiedMeContactWithKeys(toFetch: keys),
           let email = me.emailAddresses.first?.value as String? {
            return email
        }
        return nil
    }
}
