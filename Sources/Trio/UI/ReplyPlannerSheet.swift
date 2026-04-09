import SwiftUI
import AppKit

/// 返信方針プランナーシート
/// - AIが全連絡を俯瞰してグループ化した結果を表示
/// - 各グループの方針をユーザーが確認/編集/実行
struct ReplyPlannerSheet: View {
    let plan: ReplyPlanner.Plan
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ヘッダー
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(TrioTheme.accent)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    Text("返信方針プランナー")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("全メッセージをAIが分析・グループ化しました")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
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

            // サマリ
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(TrioTheme.accent)
                Text(plan.summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(TrioTheme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(TrioTheme.accent.opacity(0.08))

            // グループ一覧
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(plan.groups, id: \.theme) { group in
                        PlanGroupCard(group: group, store: store)
                    }
                }
                .padding(16)
            }
            .background(TrioTheme.background)

            Divider().overlay(TrioTheme.border)

            // フッターアクション
            HStack(spacing: 10) {
                Text("合計 \(plan.groups.reduce(0) { $0 + $1.messageIds.count }) 件")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task {
                        for group in plan.groups where group.recommendedAction == "reply" || group.recommendedAction == "skip" {
                            await store.executePlanGroup(group)
                        }
                        dismiss()
                    }
                } label: {
                    Label("推奨アクションを全て実行", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(TrioTheme.accent)
                        .foregroundColor(.white)
                        .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(TrioTheme.surface)
        }
        .background(TrioTheme.background)
    }
}

struct PlanGroupCard: View {
    let group: ReplyPlanner.Plan.Group
    @ObservedObject var store: AppStore
    @State private var expanded: Bool = true
    @State private var editedReply: String = ""
    @State private var executed: Bool = false

    private var priorityColor: Color {
        switch group.priority {
        case "urgent": return .red
        case "high": return .orange
        case "medium": return .yellow
        default: return Color.white.opacity(0.35)
        }
    }

    private var priorityLabel: String {
        switch group.priority {
        case "urgent": return "緊急"
        case "high": return "高"
        case "medium": return "通常"
        default: return "低"
        }
    }

    private var actionLabel: String {
        switch group.recommendedAction {
        case "reply": return "✉️ 返信する"
        case "skip": return "🚫 無視"
        case "later": return "⏰ あとで"
        case "custom": return "👀 個別判断"
        default: return group.recommendedAction
        }
    }

    private var actionColor: Color {
        switch group.recommendedAction {
        case "reply": return .green
        case "skip": return .red
        case "later": return .yellow
        case "custom": return .blue
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack(spacing: 10) {
                Text(priorityLabel)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(priorityColor.opacity(0.25))
                    .foregroundColor(priorityColor)
                    .cornerRadius(3)

                Text(group.theme)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(TrioTheme.primaryText)

                Text("\(group.messageIds.count)件")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                Text(actionLabel)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(actionColor.opacity(0.2))
                    .foregroundColor(actionColor)
                    .cornerRadius(5)

                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 理由
            Text("💡 \(group.reasoning)")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)

            if expanded {
                // 対象メッセージ一覧
                VStack(alignment: .leading, spacing: 4) {
                    Text("対象メッセージ")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    ForEach(group.messageIds, id: \.self) { mid in
                        if let msg = store.messages.first(where: { $0.id == mid }) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TrioTheme.serviceColor(msg.service))
                                    .frame(width: 6, height: 6)
                                Text(msg.sender)
                                    .font(.system(size: 10, weight: .medium))
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text(msg.body.prefix(50))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                }
                .padding(8)
                .background(TrioTheme.surfaceElevated)
                .cornerRadius(5)

                // デフォルト返信 (editable)
                if let suggested = group.suggestedReply, !suggested.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("デフォルト返信 (編集可)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        TextEditor(text: Binding(
                            get: { editedReply.isEmpty ? suggested : editedReply },
                            set: { editedReply = $0 }
                        ))
                        .font(.system(size: 11))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 50, maxHeight: 90)
                        .background(TrioTheme.surfaceElevated)
                        .cornerRadius(5)
                    }
                }

                // 実行ボタン
                HStack(spacing: 6) {
                    Button {
                        executed = true
                        Task {
                            var modifiedGroup = group
                            if !editedReply.isEmpty {
                                modifiedGroup = ReplyPlanner.Plan.Group(
                                    theme: group.theme,
                                    priority: group.priority,
                                    messageIds: group.messageIds,
                                    recommendedAction: group.recommendedAction,
                                    reasoning: group.reasoning,
                                    suggestedReply: editedReply,
                                    tone: group.tone
                                )
                            }
                            await store.executePlanGroup(modifiedGroup)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if executed {
                                Image(systemName: "checkmark.circle.fill")
                                Text("実行済")
                            } else {
                                Image(systemName: "play.fill")
                                Text("このグループを実行")
                            }
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(executed ? Color.green : actionColor)
                        .foregroundColor(.white)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(executed)

                    Button {
                        // このグループをスキップ (何もしない)
                    } label: {
                        Text("スキップ")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TrioTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(TrioTheme.border, lineWidth: 1)
        )
    }
}
