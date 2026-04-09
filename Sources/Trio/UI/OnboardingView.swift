import SwiftUI
import AppKit
import CoreGraphics

/// 初回起動時のセットアップツアー
struct OnboardingView: View {
    @ObservedObject var store: AppStore
    @State private var step: Int = 0
    @State private var apiKeyInput: String = ""
    @State private var apiKeyTesting = false
    @State private var apiKeyTestResult: String? = nil
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.10, blue: 0.18),
                    Color(red: 0.13, green: 0.22, blue: 0.36)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ).ignoresSafeArea()

            VStack(spacing: 24) {
                // 進捗ドット
                HStack(spacing: 8) {
                    ForEach(0..<4) { i in
                        Circle()
                            .fill(i == step ? TrioTheme.accent : Color.white.opacity(0.2))
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 24)

                Spacer()

                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: permissionStep
                    case 2: apiKeyStep
                    default: readyStep
                    }
                }
                .frame(maxWidth: 440)
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

                Spacer()

                // 戻る/次へ
                HStack {
                    if step > 0 && step < 3 {
                        Button("戻る") {
                            withAnimation { step -= 1 }
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    Button(step == 3 ? "使い始める" : "次へ") {
                        withAnimation {
                            if step == 3 {
                                onComplete()
                            } else {
                                step += 1
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .bold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [TrioTheme.accent, TrioTheme.accent.opacity(0.7)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .cornerRadius(10)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            // ロゴ
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(
                        colors: [TrioTheme.accent, Color(red: 0.25, green: 0.45, blue: 0.9)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 100, height: 100)
                    .shadow(color: TrioTheme.accent.opacity(0.4), radius: 20, x: 0, y: 10)
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 10) {
                Text("Trio へようこそ")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("メッセージを3件ずつ、タップで片付ける")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "brain.head.profile", title: "AIが重要な順に並べる",
                           desc: "Claude Haiku 4.5 が緊急度を判定")
                featureRow(icon: "sparkles", title: "返信案を5パターン提案",
                           desc: "承諾/辞退/質問/保留/詳細から選ぶだけ")
                featureRow(icon: "message.fill", title: "Slack/LINE/iMessage 対応",
                           desc: "LINE含む全サービスを横断取得")
                featureRow(icon: "lock.shield.fill", title: "プライバシー重視",
                           desc: "データは端末内に保存、外部送信なし")
            }
            .padding(20)
            .background(Color.white.opacity(0.06))
            .cornerRadius(14)
        }
    }

    private func featureRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(TrioTheme.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54))
                .foregroundColor(.orange)

            VStack(spacing: 8) {
                Text("権限を許可してください")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("Trio がメッセージを読むために\n以下の3つの権限が必要です")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                permissionRow(
                    icon: "folder.fill.badge.person.crop",
                    title: "フルディスクアクセス",
                    desc: "通知センターから全サービスのメッセージを読み取る",
                    color: .blue,
                    action: { openSetting("Privacy_AllFiles") }
                )
                permissionRow(
                    icon: "rectangle.on.rectangle.angled",
                    title: "画面収録",
                    desc: "LINEの画面を読み取る (OCR)",
                    color: .green,
                    action: {
                        // macOSの公式プロンプトを発火
                        _ = CGRequestScreenCaptureAccess()
                        // プロンプトが出ない場合は設定画面を開く
                        openSetting("Privacy_ScreenCapture")
                    }
                )
                permissionRow(
                    icon: "accessibility",
                    title: "アクセシビリティ",
                    desc: "LINEへの自動送信 (Cmd+V の自動入力)",
                    color: .purple,
                    action: { openSetting("Privacy_Accessibility") }
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.white.opacity(0.7))
                    Text("各行の「開く」ボタンで設定画面にジャンプします")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.white.opacity(0.7))
                    Text("リストに Trio があれば右のスイッチをオンにしてください")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.top, 4)
        }
    }

    private func permissionRow(
        icon: String, title: String, desc: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.2))
                .cornerRadius(8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                Text(desc).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            Button("開く") { action() }
                .buttonStyle(.plain)
                .foregroundColor(color)
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(color.opacity(0.15))
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
    }

    private func openSetting(_ key: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(key)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 2: API Key

    private var apiKeyStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "key.fill")
                .font(.system(size: 54))
                .foregroundColor(TrioTheme.accent)

            VStack(spacing: 8) {
                Text("Anthropic APIキーを設定")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("AIが返信案を生成するために必要です")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 無料のAPIキーを取得")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
                    } label: {
                        HStack(spacing: 6) {
                            Text("console.anthropic.com")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(TrioTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(TrioTheme.accent.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    Text("※ 新規登録で$5分の無料クレジットが付きます")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("2. キーを貼り付け")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    SecureField("sk-ant-api03-...", text: $apiKeyInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.15))
                        )
                }

                HStack {
                    Button {
                        Task { await testAPIKey() }
                    } label: {
                        HStack(spacing: 6) {
                            if apiKeyTesting {
                                ProgressView().controlSize(.mini).tint(.white)
                            } else {
                                Image(systemName: "checkmark.seal")
                            }
                            Text("テストして保存")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(TrioTheme.accent)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKeyInput.isEmpty || apiKeyTesting)

                    Spacer()

                    Button("スキップ (あとで設定)") {
                        withAnimation { step += 1 }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.5))
                    .font(.system(size: 11))
                }

                if let r = apiKeyTestResult {
                    Text(r)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(r.hasPrefix("✅") ? .green : .orange)
                        .padding(.top, 4)
                }
            }
            .padding(18)
            .background(Color.white.opacity(0.06))
            .cornerRadius(12)
        }
    }

    private func testAPIKey() async {
        apiKeyTesting = true
        apiKeyTestResult = nil
        defer { apiKeyTesting = false }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKeyInput, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 10,
            "messages": [["role": "user", "content": "hi"]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                // Keychainに保存
                store.settings.anthropicKey = apiKeyInput
                store.settings.mode = .byok
                apiKeyTestResult = "✅ 接続成功 — キーを保存しました"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation { step += 1 }
            } else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                if errBody.contains("credit") {
                    apiKeyTestResult = "⚠️ クレジット残高不足"
                } else if errBody.contains("invalid") || errBody.contains("authentication") {
                    apiKeyTestResult = "⚠️ キーが無効です"
                } else {
                    apiKeyTestResult = "⚠️ エラー (HTTP \(status))"
                }
            }
        } catch {
            apiKeyTestResult = "⚠️ ネットワークエラー"
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.green, Color.green.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 120, height: 120)
                    .shadow(color: .green.opacity(0.4), radius: 30, x: 0, y: 10)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundColor(.white)
            }

            VStack(spacing: 10) {
                Text("準備完了 🎉")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("あとは使い始めるだけです")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("メニューバーの 📥 アイコンをクリックして開く", systemImage: "1.circle.fill")
                Label("AIが重要度順に並べた3件が表示される", systemImage: "2.circle.fill")
                Label("⌘1 / ⌘2 / ⌘3 で返信を送信", systemImage: "3.circle.fill")
                Label("または「編集」で微修正", systemImage: "4.circle.fill")
            }
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.85))
            .padding(18)
            .background(Color.white.opacity(0.06))
            .cornerRadius(12)
        }
    }
}
