import Foundation

enum Service: String, Codable, CaseIterable, Sendable {
    case line, slack, chatwork, iMessage, mail
    case discord, telegram, messenger, whatsapp, teams
    case gmail, outlook, instagram
    case calendar, reminders, facetime
    case unknown

    var displayName: String {
        switch self {
        case .line: return "LINE"
        case .slack: return "Slack"
        case .chatwork: return "Chatwork"
        case .iMessage: return "iMessage"
        case .mail: return "Mail"
        case .discord: return "Discord"
        case .telegram: return "Telegram"
        case .messenger: return "Messenger"
        case .whatsapp: return "WhatsApp"
        case .teams: return "Teams"
        case .gmail: return "Gmail"
        case .outlook: return "Outlook"
        case .instagram: return "Instagram"
        case .calendar: return "カレンダー"
        case .reminders: return "リマインダー"
        case .facetime: return "FaceTime"
        case .unknown: return "その他"
        }
    }
}

enum MessageStatus: String, Codable, Sendable {
    case pending
    case replied
    case skipped
    case dismissed
}

final class Message: @unchecked Sendable, Identifiable {
    let id: String
    let service: Service
    let serviceIdentifier: String?
    let sender: String
    let threadId: String?
    let body: String
    let receivedAt: Date
    var status: MessageStatus
    var importanceScore: Double
    var reasonForPriority: String?
    var drafts: [ReplyDraft] = []
    var snoozeUntil: Date? = nil

    init(
        id: String,
        service: Service,
        serviceIdentifier: String? = nil,
        sender: String,
        threadId: String? = nil,
        body: String,
        receivedAt: Date,
        status: MessageStatus = .pending,
        importanceScore: Double = 0.0,
        reasonForPriority: String? = nil
    ) {
        self.id = id
        self.service = service
        self.serviceIdentifier = serviceIdentifier
        self.sender = sender
        self.threadId = threadId
        self.body = body
        self.receivedAt = receivedAt
        self.status = status
        self.importanceScore = importanceScore
        self.reasonForPriority = reasonForPriority
    }

    /// 表示用サービス名 (unknown時はbundle idから推定)
    var serviceDisplayName: String {
        if service != .unknown { return service.displayName }
        if let id = serviceIdentifier {
            // com.yuki.koe → "Koe", com.foo.bar → "Bar"
            let parts = id.split(separator: ".").map(String.init)
            if let last = parts.last {
                return last.prefix(1).uppercased() + last.dropFirst()
            }
            return id
        }
        return "その他"
    }
}

final class ReplyDraft: @unchecked Sendable {
    var text: String
    let tone: String
    let createdAt: Date

    init(text: String, tone: String, createdAt: Date = .now) {
        self.text = text
        self.tone = tone
        self.createdAt = createdAt
    }
}
