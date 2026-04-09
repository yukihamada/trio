import Foundation
import Security
import SwiftUI
import CoreImage.CIFilterBuiltins
import CryptoKit
import IOKit

/// APIキーモード
enum APIMode: String, Codable, CaseIterable {
    case byok = "byok"
    case trioCloud = "cloud"

    var displayName: String {
        switch self {
        case .byok: return "自分のAPIキー (BYOK)"
        case .trioCloud: return "Trio Cloud (月額)"
        }
    }
}

enum AppTheme: String, Codable, CaseIterable {
    case system, dark, light
    var displayName: String {
        switch self {
        case .system: return "システム"
        case .dark: return "ダーク"
        case .light: return "ライト"
        }
    }
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

/// セキュアストレージ
/// - ~/Library/Application Support/Trio/.secrets.enc に **AES-GCM暗号化** で保存 (posix 600)
/// - マスターキーは Hardware UUID + Bundle ID から決定的に派生 (デバイス固定)
enum KeychainStore {
    private static var secretsURL: URL {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Trio", isDirectory: true)
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Trio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".secrets.enc")
    }

    nonisolated(unsafe) private static var cache: [String: String]?

    /// ハードウェアUUID派生のマスターキー (CryptoKit SHA256)
    private static var masterKey: SymmetricKey {
        var platform = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, platform)
        defer { IOObjectRelease(service) }
        let uuidRef = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        let uuid = (uuidRef?.takeRetainedValue() as? String) ?? "fallback-trio-uuid"
        let seed = "ai.trio.app:secretkey:\(uuid)"
        let hash = SHA256.hash(data: Data(seed.utf8))
        return SymmetricKey(data: Data(hash))
    }

    private static func load() -> [String: String] {
        if let c = cache { return c }
        guard let encrypted = try? Data(contentsOf: secretsURL) else {
            cache = [:]
            return [:]
        }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plain = try AES.GCM.open(box, using: masterKey)
            let dict = (try? JSONDecoder().decode([String: String].self, from: plain)) ?? [:]
            cache = dict
            return dict
        } catch {
            // 復号失敗 = 破損 or 別デバイス、空扱い
            cache = [:]
            return [:]
        }
    }

    private static func persist(_ dict: [String: String]) {
        cache = dict
        guard let plain = try? JSONEncoder().encode(dict) else { return }
        do {
            let box = try AES.GCM.seal(plain, using: masterKey)
            if let combined = box.combined {
                try combined.write(to: secretsURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: secretsURL.path
                )
            }
        } catch {
            // 暗号化失敗は無視
        }
    }

    static func save(_ value: String, key: String) {
        var dict = load()
        dict[key] = value
        persist(dict)
    }

    static func read(_ key: String) -> String? {
        load()[key]
    }

    static func delete(_ key: String) {
        var dict = load()
        dict.removeValue(forKey: key)
        persist(dict)
    }
}

/// アプリ設定 (UserDefaults + Keychain)
@MainActor
final class TrioSettings: ObservableObject {
    private var initialized = false

    @Published var mode: APIMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "trio.mode") }
    }
    @Published var anthropicKey: String {
        didSet { if initialized { KeychainStore.save(anthropicKey, key: "anthropic_api_key") } }
    }
    @Published var slackToken: String {
        didSet { if initialized { KeychainStore.save(slackToken, key: "slack_token") } }
    }
    @Published var chatworkToken: String {
        didSet { if initialized { KeychainStore.save(chatworkToken, key: "chatwork_token") } }
    }
    @Published var trioCloudToken: String {
        didSet { if initialized { KeychainStore.save(trioCloudToken, key: "trio_cloud_token") } }
    }
    @Published var trioCloudEmail: String {
        didSet { UserDefaults.standard.set(trioCloudEmail, forKey: "trio.email") }
    }
    @Published var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "trio.theme")
            NSApp.appearance = appTheme.nsAppearance
        }
    }
    @Published var confirmBeforeSend: Bool {
        didSet { UserDefaults.standard.set(confirmBeforeSend, forKey: "trio.confirmSend") }
    }
    // 有効にするメッセンジャー
    @Published var enabledServices: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(enabledServices), forKey: "trio.enabledServices")
        }
    }

    func isServiceEnabled(_ service: Service) -> Bool {
        enabledServices.contains(service.rawValue)
    }

    func setService(_ service: Service, enabled: Bool) {
        if enabled {
            enabledServices.insert(service.rawValue)
        } else {
            enabledServices.remove(service.rawValue)
        }
    }

    static let trioCloudURL = "https://trio-cloud.fly.dev"

    init() {
        let raw = UserDefaults.standard.string(forKey: "trio.mode") ?? "byok"
        self.mode = APIMode(rawValue: raw) ?? .byok
        self.anthropicKey = KeychainStore.read("anthropic_api_key") ?? ""
        self.slackToken = KeychainStore.read("slack_token") ?? ""
        self.chatworkToken = KeychainStore.read("chatwork_token") ?? ""
        self.trioCloudToken = KeychainStore.read("trio_cloud_token") ?? ""
        self.trioCloudEmail = UserDefaults.standard.string(forKey: "trio.email") ?? ""
        self.appTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "trio.theme") ?? "system") ?? .system
        // デフォルトON (安全策: 初回は必ず確認ダイアログを出す)
        if UserDefaults.standard.object(forKey: "trio.confirmSend") == nil {
            self.confirmBeforeSend = true
        } else {
            self.confirmBeforeSend = UserDefaults.standard.bool(forKey: "trio.confirmSend")
        }
        if let saved = UserDefaults.standard.array(forKey: "trio.enabledServices") as? [String] {
            self.enabledServices = Set(saved)
        } else {
            self.enabledServices = Set(Service.allCases.map { $0.rawValue })
        }
        self.initialized = true  // 以降はdidSetで永続化される
    }

    /// 実際にAIに渡す情報を返す
    func resolveLLMConfig() -> LLMConfig? {
        switch mode {
        case .byok:
            guard !anthropicKey.isEmpty else { return nil }
            return LLMConfig(
                endpoint: "https://api.anthropic.com/v1/messages",
                authHeader: "x-api-key",
                authValue: anthropicKey,
                isCloud: false
            )
        case .trioCloud:
            guard !trioCloudToken.isEmpty else { return nil }
            return LLMConfig(
                endpoint: "\(Self.trioCloudURL)/v1/triage",
                authHeader: "Authorization",
                authValue: "Bearer \(trioCloudToken)",
                isCloud: true
            )
        }
    }
}

struct LLMConfig {
    let endpoint: String
    let authHeader: String
    let authValue: String
    let isCloud: Bool
}

// MARK: - Settings UI

struct SettingsView: View {
    @ObservedObject var settings: TrioSettings
    @State private var showAnthropicKey = false
    @State private var verifyMessage: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー (固定)
            HStack {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(TrioTheme.accent)
                    .font(.system(size: 18))
                Text("Trio 設定")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(TrioTheme.surface)

            Divider().overlay(TrioTheme.border)

            // メインコンテンツ (スクロール)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    aiModeSection
                    servicesSection       // 🆕 メッセンジャー選択
                    apiKeysSection
                    appearanceSection
                    fewShotSection
                    cloudSyncSection
                    dataSection
                    aboutSection
                }
                .padding(20)
            }
            .background(TrioTheme.background)
        }
        .frame(width: 540, height: 680)
    }

    // MARK: - Sections

    private var aiModeSection: some View {
        sectionCard(icon: "brain.head.profile", title: "AIエンジン", color: TrioTheme.accent) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $settings.mode) {
                    ForEach(APIMode.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if settings.mode == .byok {
                    byokSection
                } else {
                    cloudSection
                }
            }
        }
    }

    private var servicesSection: some View {
        sectionCard(icon: "bubble.left.and.bubble.right.fill", title: "メッセンジャー", color: .green) {
            VStack(spacing: 0) {
                Text("取得するサービスを選択")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)

                ForEach(Service.allCases, id: \.self) { svc in
                    serviceToggleRow(svc)
                }
            }
        }
    }

    private func serviceToggleRow(_ service: Service) -> some View {
        let enabled = settings.isServiceEnabled(service)
        let needsConfig = serviceNeedsConfig(service)
        return HStack(spacing: 10) {
            Circle()
                .fill(TrioTheme.serviceColor(service))
                .frame(width: 10, height: 10)
            Text(service.displayName)
                .font(.system(size: 12, weight: .medium))
            if needsConfig {
                Text("要APIキー")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundColor(.orange)
                    .cornerRadius(3)
            }
            Spacer()
            Text(serviceSource(service))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Toggle("", isOn: Binding(
                get: { enabled },
                set: { settings.setService(service, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.vertical, 5)
        .overlay(
            Rectangle()
                .fill(TrioTheme.border)
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }

    private func serviceNeedsConfig(_ service: Service) -> Bool {
        switch service {
        case .slack: return settings.slackToken.isEmpty
        case .chatwork: return settings.chatworkToken.isEmpty
        default: return false
        }
    }

    private func serviceSource(_ service: Service) -> String {
        switch service {
        case .line: return "OCR"
        case .slack, .chatwork: return "API"
        case .iMessage, .mail, .calendar, .reminders, .facetime: return "通知DB"
        default: return "通知DB"
        }
    }

    private var apiKeysSection: some View {
        sectionCard(icon: "key.fill", title: "APIトークン", color: .orange) {
            VStack(spacing: 10) {
                tokenField("Slack Token", binding: $settings.slackToken, hint: "xoxp-... or xoxb-...")
                tokenField("Chatwork Token", binding: $settings.chatworkToken, hint: "API Token")
            }
        }
    }

    private var appearanceSection: some View {
        sectionCard(icon: "paintbrush.fill", title: "外観・動作", color: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("テーマ").font(.system(size: 12)).frame(width: 80, alignment: .leading)
                    Picker("", selection: $settings.appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider().overlay(TrioTheme.border)
                Toggle(isOn: $settings.confirmBeforeSend) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("送信前に確認する").font(.system(size: 12, weight: .medium))
                        Text("送信ボタンを押した時に確認ダイアログを表示")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var fewShotSection: some View {
        sectionCard(icon: "sparkles", title: "学習データ (Few-shot)", color: .pink) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.pink.opacity(0.2)).frame(width: 36, height: 36)
                    Text("\(UserProfile.shared.profile.writingSamples.count)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.pink)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("送信サンプルを学習中")
                        .font(.system(size: 12, weight: .medium))
                    Text("過去の返信から文体・語尾・絵文字を学習")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("クリア") {
                    UserProfile.shared.profile.writingSamples.removeAll()
                    UserProfile.shared.save()
                }
                .controlSize(.small)
            }
        }
    }

    private var cloudSyncSection: some View {
        sectionCard(icon: "icloud.fill", title: "クラウド同期 (E2E暗号化)", color: .cyan) {
            VStack(alignment: .leading, spacing: 12) {
                // セキュリティ説明
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text("AES-256-GCMでローカル暗号化、サーバは鍵を持ちません")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                // QRコード + 鍵表示
                HStack(alignment: .top, spacing: 14) {
                    qrCodeView
                        .frame(width: 130, height: 130)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("スマホでスキャン", systemImage: "qrcode.viewfinder")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(TrioTheme.primaryText)
                        Text("iPhoneのカメラで読み取るとTrioの別端末セットアップが自動完了")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider().overlay(TrioTheme.border).padding(.vertical, 2)

                        HStack(spacing: 6) {
                            Button {
                                saveQRCode()
                            } label: {
                                Label("保存", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 10))
                            }
                            .controlSize(.mini)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(qrPayload, forType: .string)
                            } label: {
                                Label("URLコピー", systemImage: "link")
                                    .font(.system(size: 10))
                            }
                            .controlSize(.mini)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(CloudSync.shared.currentKeyHex, forType: .string)
                            } label: {
                                Label("鍵のみ", systemImage: "key")
                                    .font(.system(size: 10))
                            }
                            .controlSize(.mini)
                        }
                    }
                }

                // 手動同期ボタン
                HStack(spacing: 8) {
                    Button {
                        Task {
                            guard !settings.trioCloudToken.isEmpty else { return }
                            try? await CloudSync.shared.uploadSnapshot(
                                deviceId: Host.current().localizedName ?? "Mac",
                                userToken: settings.trioCloudToken
                            )
                        }
                    } label: {
                        Label("今すぐ同期", systemImage: "icloud.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .disabled(settings.trioCloudToken.isEmpty)

                    Button {
                        Task {
                            guard !settings.trioCloudToken.isEmpty else { return }
                            _ = try? await CloudSync.shared.downloadSnapshot(userToken: settings.trioCloudToken)
                        }
                    } label: {
                        Label("取得", systemImage: "icloud.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .disabled(settings.trioCloudToken.isEmpty)
                }

                if settings.trioCloudToken.isEmpty {
                    Text("※ Trio Cloud アカウント取得後に同期可能 (AIエンジン→Trio Cloud)")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }
        }
    }

    /// QRコードに埋め込むペイロード: trio:// カスタムURL
    private var qrPayload: String {
        let key = CloudSync.shared.currentKeyHex
        let token = settings.trioCloudToken
        let server = TrioSettings.trioCloudURL
        // URL形式: trio://setup?server=...&token=...&key=...
        var comps = URLComponents()
        comps.scheme = "trio"
        comps.host = "setup"
        comps.queryItems = [
            URLQueryItem(name: "server", value: server),
            URLQueryItem(name: "key", value: key)
        ]
        if !token.isEmpty {
            comps.queryItems?.append(URLQueryItem(name: "token", value: token))
        }
        return comps.url?.absoluteString ?? "trio://setup?key=\(key)"
    }

    @ViewBuilder
    private var qrCodeView: some View {
        if let img = Self.generateQRCode(from: qrPayload) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(6)
                .background(Color.white)
                .cornerRadius(8)
        } else {
            Rectangle()
                .fill(TrioTheme.surfaceElevated)
                .overlay(Text("QR生成エラー").font(.caption2))
        }
    }

    private func saveQRCode() {
        guard let img = Self.generateQRCode(from: qrPayload, size: 1024) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "trio_sync_qr.png"
        panel.begin { res in
            if res == .OK, let url = panel.url {
                if let tiff = img.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: url)
                }
            }
        }
    }

    static func generateQRCode(from string: String, size: CGFloat = 256) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaleX = size / output.extent.width
        let scaleY = size / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private var dataSection: some View {
        sectionCard(icon: "externaldrive.fill", title: "データ管理", color: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("~/Library/Application Support/Trio/")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text("※ このフォルダは再インストール時も消えません")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Button {
                        let url = StateStore.shared.dataDirectory
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("フォルダを開く", systemImage: "folder")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    Button {
                        let savePanel = NSSavePanel()
                        savePanel.nameFieldStringValue = "trio_backup_\(Int(Date().timeIntervalSince1970)).zip"
                        savePanel.begin { res in
                            if res == .OK, let dest = savePanel.url {
                                Self.zipBackup(to: dest)
                            }
                        }
                    } label: {
                        Label("バックアップ", systemImage: "arrow.up.doc")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    Button {
                        let openPanel = NSOpenPanel()
                        openPanel.allowedContentTypes = [.zip]
                        openPanel.begin { res in
                            if res == .OK, let src = openPanel.url {
                                Self.unzipBackup(from: src)
                            }
                        }
                    } label: {
                        Label("復元", systemImage: "arrow.down.doc")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var aboutSection: some View {
        sectionCard(icon: "info.circle.fill", title: "Trio について", color: .gray) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("バージョン").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text("0.1.0").font(.system(size: 11, design: .monospaced))
                }
                HStack {
                    Text("ポーリング間隔").font(.system(size: 11)).foregroundColor(.secondary)
                    Spacer()
                    Text("10秒").font(.system(size: 11, design: .monospaced))
                }
                if !verifyMessage.isEmpty {
                    Divider().overlay(TrioTheme.border)
                    Text(verifyMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionCard<Content: View>(
        icon: String, title: String, color: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.15))
                    .cornerRadius(5)
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(TrioTheme.primaryText)
            }
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TrioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(TrioTheme.border, lineWidth: 1)
        )
    }

    private var byokSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anthropic APIキー")
                .font(.headline)
            Text("https://console.anthropic.com で取得 ($5無料クレジット)")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                if showAnthropicKey {
                    TextField("sk-ant-...", text: $settings.anthropicKey)
                } else {
                    SecureField("sk-ant-...", text: $settings.anthropicKey)
                }
                Button(showAnthropicKey ? "隠す" : "表示") {
                    showAnthropicKey.toggle()
                }
                .controlSize(.small)
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trio Cloud アカウント")
                .font(.headline)
            Text("月額¥980 / 1日500メッセージまでAI処理。\nクレジットカード不要、メールで開始。")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("メールアドレス", text: $settings.trioCloudEmail)
                .textFieldStyle(.roundedBorder)
            SecureField("ログイントークン (メール認証後に届く)", text: $settings.trioCloudToken)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("メールで認証コードを送る") {
                    Task { await requestMagicLink() }
                }
                .controlSize(.small)
                .disabled(settings.trioCloudEmail.isEmpty)

                Button("接続テスト") {
                    Task { await verifyCloud() }
                }
                .controlSize(.small)
                .disabled(settings.trioCloudToken.isEmpty)
            }

            if !settings.trioCloudToken.isEmpty {
                Button("残クレジットを確認") {
                    Task { await checkCredits() }
                }
                .controlSize(.small)
            }
        }
    }

    private func tokenField(_ label: String, binding: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold())
            SecureField(hint, text: binding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func requestMagicLink() async {
        verifyMessage = "送信中..."
        var req = URLRequest(url: URL(string: "\(TrioSettings.trioCloudURL)/v1/auth/magiclink")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["email": settings.trioCloudEmail])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                verifyMessage = "✅ メールを確認してトークンをペーストしてください"
            } else {
                verifyMessage = "❌ サーバエラー"
            }
        } catch {
            verifyMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func verifyCloud() async {
        verifyMessage = "確認中..."
        var req = URLRequest(url: URL(string: "\(TrioSettings.trioCloudURL)/v1/me")!)
        req.setValue("Bearer \(settings.trioCloudToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let email = json["email"] as? String ?? "?"
                let credits = json["credits"] as? Int ?? 0
                verifyMessage = "✅ \(email) / 残 \(credits) credits"
            } else {
                verifyMessage = "❌ トークン無効"
            }
        } catch {
            verifyMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func checkCredits() async {
        await verifyCloud()
    }

    /// バックアップを zip 化
    static func zipBackup(to dest: URL) {
        let src = StateStore.shared.dataDirectory
        // ditto でフォルダを zip 化 (macOS 標準)
        let task = Process()
        task.launchPath = "/usr/bin/ditto"
        task.arguments = ["-c", "-k", "--sequesterRsrc", src.path, dest.path]
        try? task.run()
        task.waitUntilExit()
    }

    /// バックアップ zip を展開して復元
    static func unzipBackup(from src: URL) {
        let dest = StateStore.shared.dataDirectory
        let tmp = dest.appendingPathComponent("_restore_tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let task = Process()
        task.launchPath = "/usr/bin/ditto"
        task.arguments = ["-x", "-k", src.path, tmp.path]
        try? task.run()
        task.waitUntilExit()
        // tmp 内のファイルを dest にコピー
        if let files = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) {
            for f in files {
                let srcFile = tmp.appendingPathComponent(f)
                let destFile = dest.appendingPathComponent(f)
                try? FileManager.default.removeItem(at: destFile)
                try? FileManager.default.copyItem(at: srcFile, to: destFile)
            }
        }
        try? FileManager.default.removeItem(at: tmp)
    }
}
