import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Design Tokens

enum TrioTheme {
    // 深海ネイビー系の洗練されたダークテーマ
    static let background = Color(red: 0.055, green: 0.065, blue: 0.09)   // #0E1017
    static let surface = Color(red: 0.095, green: 0.11, blue: 0.145)      // #18202A
    static let surfaceHover = Color(red: 0.13, green: 0.15, blue: 0.19)   // #212632
    static let surfaceElevated = Color(red: 0.115, green: 0.135, blue: 0.175) // #1E2229
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)
    static let primaryText = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let accent = Color(red: 0.32, green: 0.58, blue: 1.0)          // #528EFF
    static let accentHover = Color(red: 0.42, green: 0.68, blue: 1.0)

    static let slackColor = Color(red: 0.29, green: 0.08, blue: 0.30)
    static let chatworkColor = Color(red: 0.94, green: 0.40, blue: 0.00)
    static let lineColor = Color(red: 0.02, green: 0.78, blue: 0.33)
    static let iMessageColor = Color(red: 0.18, green: 0.82, blue: 0.40)
    static let mailColor = Color(red: 0.26, green: 0.59, blue: 0.98)
    static let discordColor = Color(red: 0.35, green: 0.39, blue: 0.95)
    static let telegramColor = Color(red: 0.00, green: 0.53, blue: 0.83)
    static let messengerColor = Color(red: 0.00, green: 0.51, blue: 1.0)
    static let whatsappColor = Color(red: 0.15, green: 0.68, blue: 0.38)
    static let teamsColor = Color(red: 0.29, green: 0.36, blue: 0.68)
    static let gmailColor = Color(red: 0.90, green: 0.17, blue: 0.15)
    static let outlookColor = Color(red: 0.00, green: 0.45, blue: 0.74)
    static let instagramColor = Color(red: 0.88, green: 0.18, blue: 0.50)
    static let calendarColor = Color(red: 0.92, green: 0.23, blue: 0.28)
    static let remindersColor = Color(red: 1.00, green: 0.58, blue: 0.00)
    static let facetimeColor = Color(red: 0.20, green: 0.80, blue: 0.40)
    static let unknownColor = Color(red: 0.55, green: 0.55, blue: 0.60)

    static func serviceColor(_ s: Service) -> Color {
        switch s {
        case .slack: return slackColor
        case .chatwork: return chatworkColor
        case .line: return lineColor
        case .iMessage: return iMessageColor
        case .mail: return mailColor
        case .discord: return discordColor
        case .telegram: return telegramColor
        case .messenger: return messengerColor
        case .whatsapp: return whatsappColor
        case .teams: return teamsColor
        case .gmail: return gmailColor
        case .outlook: return outlookColor
        case .instagram: return instagramColor
        case .calendar: return calendarColor
        case .reminders: return remindersColor
        case .facetime: return facetimeColor
        case .unknown: return unknownColor
        }
    }

    static func priorityColor(_ score: Double) -> Color {
        switch score {
        case 0.85...: return Color(red: 1.0, green: 0.30, blue: 0.30)  // Red — critical
        case 0.65..<0.85: return Color(red: 1.0, green: 0.60, blue: 0.20) // Orange — high
        case 0.40..<0.65: return Color(red: 0.95, green: 0.85, blue: 0.25) // Yellow — medium
        case 0.01..<0.40: return Color.white.opacity(0.35)               // Gray — low
        default: return Color.white.opacity(0.15)
        }
    }

    static func priorityLabel(_ score: Double) -> String {
        switch score {
        case 0.85...: return "緊急"
        case 0.65..<0.85: return "重要"
        case 0.40..<0.65: return "通常"
        default: return "低"
        }
    }
}

// MARK: - Main View

struct TripleCardView: View {
    @ObservedObject var store: AppStore
    @State private var batchMode = false
    @State private var serviceFilter: Service? = nil
    @State private var searchText = ""
    @State private var showingScreenPermBanner: Bool = !CGPreflightScreenCaptureAccess()
    @State private var permCheckTimer: Timer? = nil
    @State private var sortMode: SortMode = .importance

    enum SortMode: String, CaseIterable {
        case importance = "重要度順"
        case newest = "新着順"
        case oldest = "古い順"

        var icon: String {
            switch self {
            case .importance: return "exclamationmark.triangle.fill"
            case .newest: return "arrow.down"
            case .oldest: return "arrow.up"
            }
        }
    }

    struct ServiceGroup: Identifiable {
        let service: Service
        let displayName: String
        let count: Int
        var key: String { "\(service.rawValue)_\(displayName)" }
        var id: String { key }
    }

    var uniqueServiceGroups: [ServiceGroup] {
        let pending = store.messages.filter { $0.status == .pending }
        var map: [String: (Service, String, Int)] = [:]
        for m in pending {
            let key = "\(m.service.rawValue)_\(m.serviceDisplayName)"
            let current = map[key] ?? (m.service, m.serviceDisplayName, 0)
            map[key] = (current.0, current.1, current.2 + 1)
        }
        return map.values
            .sorted { $0.2 > $1.2 }
            .map { ServiceGroup(service: $0.0, displayName: $0.1, count: $0.2) }
    }

    var filteredMessages: [Message] {
        var result = store.messages.filter { $0.status == .pending }
        if let svc = serviceFilter {
            result = result.filter { $0.service == svc }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.sender.localizedCaseInsensitiveContains(searchText) ||
                $0.body.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortMode {
        case .importance:
            return result.sorted { $0.importanceScore > $1.importanceScore }
        case .newest:
            return result.sorted { $0.receivedAt > $1.receivedAt }
        case .oldest:
            return result.sorted { $0.receivedAt < $1.receivedAt }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                TrioTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    if let err = store.lastError {
                        errorBanner(err)
                    }

                    if showingScreenPermBanner {
                        lineOCRBanner
                    }

                    if store.undoableMessageId != nil {
                        undoBanner
                    }

                    if store.lineScanning || !store.lineScanProgress.isEmpty {
                        HStack(spacing: 8) {
                            if store.lineScanning {
                                ProgressView().controlSize(.mini)
                            }
                            Text(store.lineScanProgress)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(TrioTheme.primaryText)
                            Spacer()
                            if !store.lineScanning {
                                Button {
                                    store.lineScanProgress = ""
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 9))
                                        .foregroundColor(TrioTheme.tertiaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.08))
                    }

                    commandBar

                    filterBar

                    if batchMode && store.selectedCount > 0 {
                        batchActionBar
                    }

                    Divider().overlay(TrioTheme.border)

                    if filteredMessages.isEmpty && !store.isLoading {
                        if store.needsFDA {
                            permissionNeededState
                        } else {
                            emptyState
                        }
                    } else {
                        cardGrid(width: geo.size.width)
                    }

                    footer
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 560, minHeight: 620, idealHeight: 760)
        .background(KeyHandler(store: store))
        .sheet(isPresented: $store.showSettings) {
            SettingsView(settings: store.settings)
                .background(TrioTheme.background)
        }
        .sheet(isPresented: $store.showOnboarding) {
            OnboardingView(store: store) {
                store.completeOnboarding()
                Task { await store.refresh() }
            }
            .frame(width: 560, height: 720)
        }
        .sheet(isPresented: $store.showHelp) {
            HelpSheet(isShown: $store.showHelp)
                .frame(width: 480, height: 520)
        }
        .sheet(isPresented: $store.showPlanner) {
            if let plan = store.currentPlan {
                ReplyPlannerSheet(plan: plan, store: store)
                    .frame(width: 640, height: 720)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Logo
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [TrioTheme.accent, TrioTheme.accent.opacity(0.6)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 32, height: 32)
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Trio")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(TrioTheme.primaryText)
                HStack(spacing: 6) {
                    Text("\(store.pendingCount) 未処理")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(TrioTheme.secondaryText)
                    if store.processedCount > 0 {
                        Text("·").foregroundColor(TrioTheme.tertiaryText)
                        Text("今日 \(store.processedCount) 処理済")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                    }
                    if let last = store.lastRefreshed {
                        Text("·").foregroundColor(TrioTheme.tertiaryText)
                        Text(relativeTime(last))
                            .font(.system(size: 11))
                            .foregroundColor(TrioTheme.tertiaryText)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 6) {
                // Webで開く (トークン付き安全URL)
                iconButton(icon: "globe", active: false, tooltip: "スマホ/Webで開く") {
                    Task {
                        await ServerRelay.shared.uploadState(store: store)
                        // ローカルWebトークン読み込み
                        let tokenURL = URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Library/Application Support/Trio/.web_token")
                        let localToken = (try? String(contentsOf: tokenURL, encoding: .utf8))?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let baseURL = WebServer.shared.lanURL ?? WebServer.shared.localURL
                        let url = URL(string: "\(baseURL)/?token=\(localToken)")!
                        NSWorkspace.shared.open(url)
                    }
                }

                iconButton(icon: "questionmark.circle", tooltip: "ヘルプ (⌘?)") {
                    store.showHelp = true
                }

                iconButton(
                    icon: batchMode ? "checkmark.square.fill" : "square",
                    active: batchMode,
                    tooltip: "一括モード"
                ) { batchMode.toggle() }

                iconButton(
                    icon: "brain.head.profile",
                    active: store.showPlanner,
                    spinning: store.planGenerating,
                    tooltip: "返信方針プランナー"
                ) {
                    Task { await store.generatePlan() }
                }

                iconButton(
                    icon: store.lineScanning ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle",
                    active: store.lineScanning,
                    spinning: store.lineScanning,
                    tooltip: "LINE全走査"
                ) {
                    Task { await store.runLineFullScan() }
                }

                iconButton(icon: "gearshape", tooltip: "設定") {
                    store.showSettings = true
                }

                iconButton(
                    icon: store.isLoading ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                    spinning: store.isLoading,
                    tooltip: "更新 (⌘R)"
                ) {
                    Task { await store.refresh() }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(TrioTheme.surface)
    }

    private func iconButton(
        icon: String, active: Bool = false, spinning: Bool = false,
        tooltip: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? TrioTheme.accent : TrioTheme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(active ? TrioTheme.accent.opacity(0.15) : Color.clear)
                )
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: Filter

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "すべて", count: store.pendingCount, selected: serviceFilter == nil) {
                    serviceFilter = nil
                }
                ForEach(uniqueServiceGroups, id: \.key) { group in
                    filterChip(
                        label: group.displayName,
                        count: group.count,
                        color: TrioTheme.serviceColor(group.service),
                        selected: serviceFilter == group.service
                    ) {
                        serviceFilter = serviceFilter == group.service ? nil : group.service
                    }
                }
                Spacer()
                // ソート切替
                Menu {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            HStack {
                                if sortMode == mode {
                                    Image(systemName: "checkmark")
                                }
                                Image(systemName: mode.icon)
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sortMode.icon)
                            .font(.system(size: 9))
                        Text(sortMode.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(TrioTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TrioTheme.surfaceElevated)
                    .cornerRadius(5)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    private func filterChip(
        label: String, count: Int, color: Color = TrioTheme.accent,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(TrioTheme.tertiaryText)
            }
            .foregroundColor(selected ? TrioTheme.primaryText : TrioTheme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? TrioTheme.surfaceElevated : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selected ? TrioTheme.borderStrong : TrioTheme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Batch

    private var batchActionBar: some View {
        HStack {
            Text("\(store.selectedCount) 件選択中")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(TrioTheme.primaryText)
            Spacer()
            Button {
                Task { await store.sendSelected() }
            } label: {
                Label("一括送信", systemImage: "paperplane.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(TrioTheme.accent)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            Button("解除") { store.clearSelection() }
                .buttonStyle(.plain)
                .foregroundColor(TrioTheme.secondaryText)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(TrioTheme.accent.opacity(0.1))
    }

    // MARK: Undo Banner (3秒以内の送信取り消し)
    private var undoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("✅ 送信しました")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(TrioTheme.primaryText)
                if let text = store.undoableText {
                    Text(text)
                        .font(.system(size: 10))
                        .foregroundColor(TrioTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                store.undoLastSend()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("取り消す (\(store.undoCountdown))")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.85))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.12))
        .overlay(Rectangle().fill(Color.green).frame(width: 3), alignment: .leading)
    }

    // MARK: Search + Command Bar (統合)
    /// 先頭が "/" の時はLLMコマンド、それ以外は検索フィルタ
    private var isCommandMode: Bool {
        searchText.trimmingCharacters(in: .whitespaces).hasPrefix("/")
    }

    private var commandBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: isCommandMode ? "wand.and.stars" : "magnifyingglass")
                    .foregroundColor(isCommandMode ? TrioTheme.accent : TrioTheme.secondaryText)
                    .font(.system(size: 13))
                    .animation(.easeInOut(duration: 0.2), value: isCommandMode)

                TextField(
                    isCommandMode ? "指示を入力 (例: /誕生日の人全員にお礼)" : "検索 or / でAI指示モード",
                    text: $searchText,
                    onCommit: {
                        if isCommandMode {
                            let cmd = String(searchText.drop(while: { $0 == "/" || $0 == " " }))
                            store.commandBarInput = cmd
                            Task { await store.executeCommand() }
                            searchText = ""
                        }
                    }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(TrioTheme.primaryText)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(TrioTheme.tertiaryText)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }

                if isCommandMode {
                    if store.commandBarProcessing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            let cmd = String(searchText.drop(while: { $0 == "/" || $0 == " " }))
                            store.commandBarInput = cmd
                            Task { await store.executeCommand() }
                            searchText = ""
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("AI実行")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                LinearGradient(
                                    colors: [TrioTheme.accent, TrioTheme.accent.opacity(0.75)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCommandMode ? TrioTheme.accent.opacity(0.08) : TrioTheme.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isCommandMode ? TrioTheme.accent.opacity(0.5) : TrioTheme.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)

            if let result = store.commandBarResult {
                HStack(spacing: 6) {
                    Text(result)
                        .font(.system(size: 10))
                        .foregroundColor(result.hasPrefix("✅") ? .green : .orange)
                    Spacer()
                    Button {
                        store.commandBarResult = nil
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                            .foregroundColor(TrioTheme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 18)
            }
        }
        .padding(.top, 8)
    }

    // MARK: LINE OCR permission banner
    private var lineOCRBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .foregroundColor(.green)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("LINEを取得するには画面収録権限が必要です")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(TrioTheme.primaryText)
                Text("許可後も表示されていたら Trio を再起動")
                    .font(.system(size: 10))
                    .foregroundColor(TrioTheme.secondaryText)
            }
            Spacer()
            Button("許可をリクエスト") {
                let granted = CGRequestScreenCaptureAccess()
                if granted {
                    showingScreenPermBanner = false
                    Task { await store.refresh() }
                } else {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                    // 権限取得を監視: 5秒ごとにチェック
                    startPermissionPolling()
                }
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green)
            .cornerRadius(6)

            Button("再起動") {
                let url = Bundle.main.bundleURL
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = [url.path]
                try? task.run()
                // 1秒後にself終了
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSApp.terminate(nil)
                }
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.green)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.15))
            .cornerRadius(5)

            Button {
                showingScreenPermBanner = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(TrioTheme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.1))
        .overlay(Rectangle().fill(Color.green).frame(width: 3), alignment: .leading)
        .onAppear {
            if showingScreenPermBanner {
                startPermissionPolling()
            }
        }
        .onDisappear {
            permCheckTimer?.invalidate()
            permCheckTimer = nil
        }
    }

    private func startPermissionPolling() {
        permCheckTimer?.invalidate()
        permCheckTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { t in
            if CGPreflightScreenCaptureAccess() {
                DispatchQueue.main.async {
                    showingScreenPermBanner = false
                    Task { await store.refresh() }
                }
                t.invalidate()
            }
        }
    }

    // MARK: Error banner

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))
            Text(err)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(TrioTheme.primaryText)
                .lineLimit(2)
            Spacer()
            Button("設定を開く") { store.showSettings = true }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.orange)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(Rectangle().fill(Color.orange).frame(width: 3), alignment: .leading)
    }

    // MARK: Card Grid (adaptive)

    private func cardGrid(width: CGFloat) -> some View {
        ScrollView {
            LazyVGrid(
                columns: gridColumns(for: width),
                spacing: 12
            ) {
                ForEach(Array(filteredMessages.enumerated()), id: \.element.id) { idx, msg in
                    MessageCard(
                        index: idx < 3 ? idx : nil,
                        message: msg,
                        store: store,
                        batchMode: batchMode
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.85))
                    ))
                }
            }
            .padding(14)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: filteredMessages.map { $0.id })
        }
    }

    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let cardMinWidth: CGFloat = 420
        let count = max(1, Int(width / cardMinWidth))
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    // MARK: Empty / Permission

    private var emptyState: some View {
        InboxZeroCelebration(processedCount: store.processedCount)
    }

    private var permissionNeededState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text("初回セットアップ")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(TrioTheme.primaryText)
                }
                Text("Trio にメッセージへのアクセス権限を付与してください")
                    .font(.system(size: 12))
                    .foregroundColor(TrioTheme.secondaryText)
            }

            VStack(spacing: 10) {
                permRow(
                    icon: "folder.fill.badge.person.crop",
                    title: "フルディスクアクセス",
                    subtitle: "通知DBから全メッセージを読み取る",
                    settingKey: "Privacy_AllFiles"
                )
                permRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "画面収録",
                    subtitle: "LINEウィンドウをOCRで取得",
                    settingKey: "Privacy_ScreenCapture"
                )
                permRow(
                    icon: "accessibility",
                    title: "アクセシビリティ",
                    subtitle: "LINEへの自動送信 (Cmd+K, Cmd+V)",
                    settingKey: "Privacy_Accessibility"
                )
            }

            Button {
                Task { await store.refresh() }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("再試行").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(TrioTheme.accent)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func permRow(icon: String, title: String, subtitle: String, settingKey: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(TrioTheme.accent)
                .frame(width: 28, height: 28)
                .background(TrioTheme.accent.opacity(0.15))
                .cornerRadius(6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(TrioTheme.primaryText)
                Text(subtitle).font(.system(size: 10)).foregroundColor(TrioTheme.secondaryText)
            }
            Spacer()
            Button("開く") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingKey)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(TrioTheme.accent)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(TrioTheme.accent.opacity(0.12))
            .cornerRadius(5)
        }
        .padding(10)
        .background(TrioTheme.surfaceElevated)
        .cornerRadius(8)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            shortcutHint("⌘1·2·3", "送信")
            shortcutHint("⌘E", "編集")
            shortcutHint("⌘R", "更新")
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 10))
                    .foregroundColor(TrioTheme.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(TrioTheme.surface)
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(TrioTheme.secondaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(TrioTheme.surfaceElevated)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(TrioTheme.border))
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(TrioTheme.tertiaryText)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Message Card

struct MessageCard: View {
    let index: Int?
    let message: Message
    @ObservedObject var store: AppStore
    let batchMode: Bool

    @State private var showFullBody: Bool = false
    @State private var selectedDraftIndex: Int? = nil
    @State private var editedText: String = ""
    @State private var sending: Bool = false
    @State private var hover = false
    @State private var showAllReplies: Bool = false

    @State private var swipeOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            // Priority bar (left edge)
            Rectangle()
                .fill(TrioTheme.priorityColor(message.importanceScore))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 10) {
                cardHeader
                messageBody
                if let reason = message.reasonForPriority, !reason.isEmpty {
                    priorityReason(reason)
                }
                Divider().overlay(TrioTheme.border)
                // 最上部にクイック返信バー (ベスト返信を1クリック送信)
                if selectedDraftIndex == nil, let first = message.drafts.first {
                    quickReplyBar(bestDraft: first)
                }
                if !message.drafts.isEmpty {
                    replyCards
                } else {
                    noDraftPlaceholder
                }
                cardFooterButtons
            }
            .padding(14)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hover ? TrioTheme.surfaceHover : TrioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    store.isSelected(message.id) && batchMode ? TrioTheme.accent : TrioTheme.border,
                    lineWidth: store.isSelected(message.id) && batchMode ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .offset(x: swipeOffset)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { v in
                    if v.translation.width < 0 {
                        swipeOffset = v.translation.width
                    }
                }
                .onEnded { v in
                    if v.translation.width < -100 {
                        // 左スワイプでスキップ
                        withAnimation(.easeOut(duration: 0.2)) { swipeOffset = -500 }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            store.skip(message: message)
                        }
                    } else {
                        withAnimation(.spring(response: 0.3)) { swipeOffset = 0 }
                    }
                }
        )
        .onHover { hover = $0 }
    }

    private var cardHeader: some View {
        HStack(spacing: 10) {
            if batchMode {
                Button {
                    store.toggleSelected(message.id)
                } label: {
                    Image(systemName: store.isSelected(message.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundColor(store.isSelected(message.id) ? TrioTheme.accent : TrioTheme.secondaryText)
                }
                .buttonStyle(.plain)
            }

            // Avatar
            ZStack {
                Circle()
                    .fill(TrioTheme.serviceColor(message.service).opacity(0.25))
                    .overlay(
                        Circle().stroke(TrioTheme.serviceColor(message.service), lineWidth: 1.5)
                    )
                    .frame(width: 38, height: 38)
                Text(initials(from: message.sender))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(TrioTheme.primaryText)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.sender)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(TrioTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(message.serviceDisplayName)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(TrioTheme.serviceColor(message.service).opacity(0.25))
                        .foregroundColor(TrioTheme.serviceColor(message.service))
                        .cornerRadius(3)
                    Text("·").foregroundColor(TrioTheme.tertiaryText)
                    Text(relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(TrioTheme.tertiaryText)
                }
            }

            Spacer()

            // Priority badge + shortcut
            VStack(alignment: .trailing, spacing: 4) {
                // × スキップボタン (右上)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { swipeOffset = -500 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        store.skip(message: message)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TrioTheme.tertiaryText)
                        .padding(5)
                        .background(Circle().fill(TrioTheme.surfaceElevated))
                }
                .buttonStyle(.plain)
                .help("スキップ (S)")

                if message.importanceScore > 0 {
                    Text(TrioTheme.priorityLabel(message.importanceScore))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TrioTheme.priorityColor(message.importanceScore).opacity(0.25))
                        .foregroundColor(TrioTheme.priorityColor(message.importanceScore))
                        .cornerRadius(3)
                }
                if let idx = index {
                    Text("⌘\(idx + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(TrioTheme.accent.opacity(0.2))
                        .foregroundColor(TrioTheme.accent)
                        .cornerRadius(3)
                }
            }
        }
    }

    /// 本文サマリー (デフォルト=1-2行) → クリックで全文展開
    private var messageBody: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showFullBody.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text(messageSummary)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(TrioTheme.primaryText)
                        .lineLimit(showFullBody ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: showFullBody ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(TrioTheme.tertiaryText)
                }
                if showFullBody {
                    Divider().overlay(TrioTheme.border)
                    Text(message.body)
                        .font(.system(size: 11))
                        .foregroundColor(TrioTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    /// 本文の最初の1行を要約として表示 (改行を半角スペースに)
    private var messageSummary: String {
        let s = message.body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    private func priorityReason(_ reason: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 9))
                .foregroundColor(TrioTheme.priorityColor(message.importanceScore))
            Text(reason)
                .font(.system(size: 10))
                .foregroundColor(TrioTheme.secondaryText)
                .lineLimit(2)
        }
    }

    /// クイック返信バー: 1クリックでベスト返信 即送信 (確認ダイアログなし)
    private func quickReplyBar(bestDraft: ReplyDraft) -> some View {
        let color = toneColor(bestDraft.tone)
        return Button {
            sending = true
            Task {
                // クイック返信は常にconfirmスキップ
                await store.send(message: message, draftIndex: 0, overrideText: bestDraft.text, fromWeb: true)
                sending = false
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [color, color.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 32, height: 32)
                    if sending {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("⚡ クイック返信")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(color)
                        Text("(\(toneLabel(bestDraft.tone)))")
                            .font(.system(size: 9))
                            .foregroundColor(TrioTheme.tertiaryText)
                    }
                    Text(bestDraft.text)
                        .font(.system(size: 12))
                        .foregroundColor(TrioTheme.primaryText)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12))
                    .foregroundColor(color)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color.opacity(0.4), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(sending)
    }

    /// 返信案リスト or 編集画面
    @ViewBuilder
    private var replyCards: some View {
        if let idx = selectedDraftIndex, idx < message.drafts.count {
            editComposer(index: idx)
        } else {
            replyOptionList
        }
    }

    /// 返信案のリスト (デフォルト3件、もっと見るで全件)
    private var replyOptionList: some View {
        let visibleCount = showAllReplies ? message.drafts.count : min(3, message.drafts.count)
        let hasMore = message.drafts.count > 3
        return VStack(spacing: 5) {
            ForEach(0..<visibleCount, id: \.self) { idx in
                replyOptionRow(index: idx, draft: message.drafts[idx])
            }
            if hasMore {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAllReplies.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAllReplies ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                        Text(showAllReplies ? "閉じる" : "もっと見る (+\(message.drafts.count - 3))")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(TrioTheme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(TrioTheme.accent.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func replyOptionRow(index idx: Int, draft: ReplyDraft) -> some View {
        let color = toneColor(draft.tone)
        HStack(spacing: 10) {
            // 番号バッジ (ショートカットヒント)
            if idx < 9 {
                Text("\(idx + 1)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(color.opacity(0.18)))
                    .overlay(Circle().stroke(color.opacity(0.4), lineWidth: 1))
            }

            VStack(spacing: 1) {
                Image(systemName: toneIcon(draft.tone))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(color)
                Text(toneLabel(draft.tone))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(color)
            }
            .frame(width: 42)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .cornerRadius(5)

            Text(draft.text)
                .font(.system(size: 12))
                .foregroundColor(TrioTheme.primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // クイック送信ボタン (即送信)
            Button {
                sending = true
                Task {
                    await store.send(message: message, draftIndex: idx, overrideText: draft.text)
                    sending = false
                }
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(color)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("即送信")

            // 編集ボタン
            Button {
                editedText = draft.text
                selectedDraftIndex = idx
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(TrioTheme.secondaryText)
                    .padding(6)
                    .background(TrioTheme.surfaceElevated)
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("編集してから送信")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // ダブルクリック = 即送信
            sending = true
            Task {
                await store.send(message: message, draftIndex: idx, overrideText: draft.text)
                sending = false
            }
        }
    }

    /// 編集+送信画面
    private func editComposer(index: Int) -> some View {
        let draft = message.drafts[index]
        let color = toneColor(draft.tone)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    selectedDraftIndex = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10))
                        Text("戻る").font(.system(size: 10))
                    }
                    .foregroundColor(TrioTheme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(TrioTheme.surfaceElevated)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)

                HStack(spacing: 4) {
                    Image(systemName: toneIcon(draft.tone))
                        .font(.system(size: 10))
                    Text(toneLabel(draft.tone))
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundColor(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.15))
                .cornerRadius(5)

                Spacer()
            }

            TextEditor(text: $editedText)
                .font(.system(size: 13))
                .foregroundColor(TrioTheme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 80, maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.5), lineWidth: 1)
                )
                .background(EditorKeyHandler(
                    onSend: {
                        message.drafts[index].text = editedText
                        sending = true
                        Task {
                            await store.send(message: message, draftIndex: index, overrideText: editedText)
                            sending = false
                            selectedDraftIndex = nil
                        }
                    },
                    onCancel: {
                        selectedDraftIndex = nil
                    }
                ))

            Text("⌘↩ 送信 · Esc 戻る")
                .font(.system(size: 9))
                .foregroundColor(TrioTheme.tertiaryText)

            HStack {
                // 送信ボタン (大)
                Button {
                    draft.text = editedText
                    sending = true
                    Task {
                        await store.send(message: message, draftIndex: index, overrideText: editedText)
                        sending = false
                        selectedDraftIndex = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        if sending {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill").font(.system(size: 12))
                        }
                        Text("送信").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [color, color.opacity(0.75)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(sending || editedText.isEmpty)

                Spacer()

                // クリップボードコピー
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editedText, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                        Text("コピー").font(.system(size: 10))
                    }
                    .foregroundColor(TrioTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(TrioTheme.surfaceElevated)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func toneLabel(_ tone: String) -> String {
        switch tone {
        case "yes": return "承諾"
        case "yes_polite": return "丁寧承諾"
        case "yes_detail": return "詳細承諾"
        case "no": return "辞退"
        case "no_polite": return "代替案"
        case "ask": return "質問"
        case "ask_detail": return "詳細質問"
        case "later": return "保留"
        case "detail": return "詳細"
        case "casual": return "カジュアル"
        case "emoji": return "絵文字"
        case "thanks": return "お礼"
        case "suggest": return "提案"
        case "instructed": return "指示系"
        case "polite": return "丁寧"
        case "short": return "短文"
        default: return tone
        }
    }

    private func toneIcon(_ tone: String) -> String {
        switch tone {
        case "yes": return "checkmark.circle.fill"
        case "yes_polite": return "checkmark.seal.fill"
        case "yes_detail": return "checklist.checked"
        case "no": return "xmark.circle.fill"
        case "no_polite": return "arrow.triangle.swap"
        case "ask": return "questionmark.circle.fill"
        case "ask_detail": return "questionmark.square.fill"
        case "later": return "clock.fill"
        case "detail": return "text.alignleft"
        case "casual": return "face.smiling"
        case "emoji": return "face.smiling.inverse"
        case "thanks": return "heart.fill"
        case "suggest": return "lightbulb.fill"
        case "instructed": return "wand.and.stars"
        case "polite": return "person.crop.circle.badge.checkmark"
        case "short": return "bolt.fill"
        default: return "text.bubble"
        }
    }

    private func toneColor(_ tone: String) -> Color {
        switch tone {
        case "yes", "yes_polite", "yes_detail": return Color.green
        case "no", "no_polite": return Color.red.opacity(0.85)
        case "ask", "ask_detail": return Color.orange
        case "later": return Color.yellow
        case "detail": return TrioTheme.accent
        case "casual": return Color.purple
        case "emoji": return Color.pink
        case "thanks": return Color(red: 1.0, green: 0.45, blue: 0.55)
        case "suggest": return Color(red: 0.95, green: 0.75, blue: 0.1)
        case "instructed": return TrioTheme.accent
        default: return TrioTheme.accent
        }
    }

    private var noDraftPlaceholder: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundColor(TrioTheme.tertiaryText)
            Text("返信案なし (APIキー未設定?)")
                .font(.system(size: 11))
                .foregroundColor(TrioTheme.tertiaryText)
        }
        .padding(8)
    }

    private var cardFooterButtons: some View {
        HStack(spacing: 6) {
            Button {
                store.regenerateDraft(message: message)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                    Text("別の案を生成").font(.system(size: 10))
                }
                .foregroundColor(TrioTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TrioTheme.surfaceElevated)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Spacer()

            Menu {
                Button("4時間後") {
                    store.snooze(message: message, until: Date().addingTimeInterval(4*3600))
                }
                Button("明日の朝9時") {
                    store.snooze(message: message, until: tomorrowMorning9AM())
                }
                Button("月曜の朝9時") {
                    store.snooze(message: message, until: nextMonday9AM())
                }
                Divider()
                Button("永久スキップ") {
                    store.skip(message: message)
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text("後で").font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .foregroundColor(TrioTheme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(TrioTheme.surfaceElevated)
                .cornerRadius(5)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func tomorrowMorning9AM() -> Date {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private func nextMonday9AM() -> Date {
        let cal = Calendar.current
        var d = Date()
        while cal.component(.weekday, from: d) != 2 { // Monday=2 in Calendar
            d = cal.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: d) ?? d
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).map { String($0) }
        if parts.count >= 2 {
            return (parts[0].first.map(String.init) ?? "") + (parts[1].first.map(String.init) ?? "")
        }
        return String(name.prefix(2))
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: message.receivedAt, relativeTo: Date())
    }
}

// MARK: - Help Sheet

struct HelpSheet: View {
    @Binding var isShown: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TrioTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("使い方ガイド")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        helpSection(
                            title: "基本の流れ",
                            icon: "play.circle.fill",
                            items: [
                                ("1. 起動", "AIが自動でメッセージを取得・整理"),
                                ("2. 選ぶ", "重要度順に並んだカードから返信を選ぶ"),
                                ("3. 送信", "⌘1/⌘2/⌘3 または「送信」ボタン"),
                                ("4. 繰り返す", "次の3件が自動で繰り上がる")
                            ]
                        )

                        helpSection(
                            title: "返信の選び方",
                            icon: "sparkles",
                            items: [
                                ("✅ 承諾", "「はい/参加します」系"),
                                ("❌ 辞退", "「難しい/今回は見送り」系"),
                                ("❓ 質問", "相手に聞き返す"),
                                ("⏰ 保留", "「後で確認します」"),
                                ("📝 詳細", "具体的な情報を含む長文"),
                                ("😊 カジュアル", "親しい相手向け")
                            ]
                        )

                        helpSection(
                            title: "ショートカット",
                            icon: "keyboard.fill",
                            items: [
                                ("⌘1 / ⌘2 / ⌘3", "上位3件を即送信"),
                                ("⌘R", "メッセージを更新"),
                                ("⌘?", "このヘルプ"),
                                ("⌘,", "設定を開く")
                            ]
                        )

                        helpSection(
                            title: "困ったときは",
                            icon: "exclamationmark.circle.fill",
                            items: [
                                ("メッセージが0件", "フルディスクアクセス権限を確認"),
                                ("LINE取れない", "画面収録権限 + LINE.app起動中か確認"),
                                ("AI応答なし", "Anthropic APIキーとクレジット残高を確認"),
                                ("送信失敗", "アクセシビリティ権限 (LINEの場合)")
                            ]
                        )
                    }
                    .padding(.bottom, 20)
                }

                HStack {
                    Spacer()
                    Button("閉じる") { isShown = false }
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(TrioTheme.accent)
                        .cornerRadius(8)
                }
            }
            .padding(28)
        }
    }

    private func helpSection(title: String, icon: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(TrioTheme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.0) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text(item.0)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .frame(width: 110, alignment: .leading)
                        Text(item.1)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .cornerRadius(8)
        }
    }
}

// MARK: - Inbox Zero Celebration
struct InboxZeroCelebration: View {
    let processedCount: Int
    @State private var confettiPieces: [ConfettiPiece] = []
    @State private var scale: CGFloat = 0.6
    @State private var glow: Double = 0.3

    struct ConfettiPiece: Identifiable {
        let id = UUID()
        var x: CGFloat
        var y: CGFloat
        var rotation: Double
        var color: Color
    }

    var body: some View {
        ZStack {
            // 紙吹雪
            ForEach(confettiPieces) { piece in
                Rectangle()
                    .fill(piece.color)
                    .frame(width: 8, height: 14)
                    .rotationEffect(.degrees(piece.rotation))
                    .position(x: piece.x, y: piece.y)
            }
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color.green.opacity(glow), Color.green.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .frame(width: 140, height: 140)
                        .blur(radius: 20)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 72, weight: .bold))
                        .foregroundStyle(LinearGradient(
                            colors: [Color.green, Color.green.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .scaleEffect(scale)
                }
                Text("Inbox Zero 🎉")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundColor(TrioTheme.primaryText)
                if processedCount > 0 {
                    Text("今日 \(processedCount) 件のメッセージを処理しました")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TrioTheme.secondaryText)
                    Text("お疲れ様でした！")
                        .font(.system(size: 12))
                        .foregroundColor(TrioTheme.tertiaryText)
                } else {
                    Text("すべてのメッセージに対応済みです")
                        .font(.system(size: 13))
                        .foregroundColor(TrioTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.5)) {
                scale = 1.0
            }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glow = 0.7
            }
            launchConfetti()
        }
    }

    private func launchConfetti() {
        let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
        for _ in 0..<30 {
            let piece = ConfettiPiece(
                x: CGFloat.random(in: 0...500),
                y: -20,
                rotation: Double.random(in: 0...360),
                color: colors.randomElement() ?? .green
            )
            confettiPieces.append(piece)
        }
        for (i, _) in confettiPieces.enumerated() {
            withAnimation(.easeIn(duration: Double.random(in: 2.5...4.0)).delay(Double(i) * 0.05)) {
                confettiPieces[i].y = 600
                confettiPieces[i].rotation += 720
            }
        }
        // 3秒後にフェードアウト
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation(.easeOut(duration: 1.0)) {
                confettiPieces = []
            }
        }
    }
}

// MARK: - Editor Key Handler (⌘↩ 送信, Esc 戻る)
struct EditorKeyHandler: NSViewRepresentable {
    var onSend: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EditorKeyView()
        view.onSend = onSend
        view.onCancel = onCancel
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EditorKeyView)?.onSend = onSend
        (nsView as? EditorKeyView)?.onCancel = onCancel
    }
}

class EditorKeyView: NSView {
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard self.window == event.window else { return event }
            let cmd = event.modifierFlags.contains(.command)
            if cmd, event.keyCode == 36 { // Cmd+Return
                self.onSend?()
                return nil
            }
            if event.keyCode == 53 { // Esc
                self.onCancel?()
                return nil
            }
            return event
        }
    }

    override func removeFromSuperview() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        super.removeFromSuperview()
    }
}

// MARK: - KeyHandler (unchanged)

struct KeyHandler: NSViewRepresentable {
    let store: AppStore

    func makeNSView(context: Context) -> NSView {
        let view = KeyHandlerView()
        view.store = store
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class KeyHandlerView: NSView {
    weak var store: AppStore?
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let store = store else { return super.keyDown(with: event) }
        let cmd = event.modifierFlags.contains(.command)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // 最優先メッセージ取得
        let pending = store.messages
            .filter { $0.status == .pending }
            .sorted { $0.importanceScore > $1.importanceScore }
        guard let primary = pending.first else {
            super.keyDown(with: event)
            return
        }

        if cmd {
            switch key {
            case "r":
                Task { await store.refresh() }
                return
            case "?", "/":
                Task { @MainActor in store.showHelp = true }
                return
            case ",":
                Task { @MainActor in store.showSettings = true }
                return
            case "k":
                Task { @MainActor in store.showCommandBar = true }
                return
            default: break
            }
        } else {
            // 単独キー操作: 番号キーで返信送信、S/Jでスキップ
            if let num = Int(key), num >= 1 && num <= 9 {
                let idx = num - 1
                if idx < primary.drafts.count {
                    Task { await store.send(message: primary, draftIndex: idx) }
                    return
                }
            }
            switch key {
            case "s", "l":  // skip/later
                Task { @MainActor in store.skip(message: primary) }
                return
            case "j":  // 次のメッセージに進む (スクロール)
                return
            case "k":  // 前のメッセージ
                return
            case "e":  // 最初の返信を編集モードで開く
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}
