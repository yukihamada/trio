# Trio — macOSメッセージ横断トリアージアプリ

## コンセプト
全メッセージサービス（Slack/Chatwork/LINE/iMessage等）を横断監視 → AIが重要度順に並べ、各メッセージに返信案を事前生成 → ユーザーは **3件ずつ表示されるカードをタップで送信** していくだけ。

## MVP v0.1 スコープ
- **対応サービス**: Slack, Chatwork, LINE, iMessage（読み取り）
- **取得方式**:
  - Slack/Chatwork: 公式API
  - LINE/他全アプリ: **macOS通知センターDB** (`~DARWIN_USER_DIR/0/com.apple.notificationcenter/db2/db`)
  - iMessage: `~/Library/Messages/chat.db`
- **AI**: Claude Haiku 4.5 で一括バッチ生成（重要度 + 返信案1本）
- **送信**:
  - Slack/Chatwork: API直接POST
  - LINE: LINE.appフォーカス + クリップボードペースト半自動
  - iMessage: AppleScript `tell application "Messages"`
- **UI**: メニューバーアプリ（`LSUIElement=YES`）、3件カード→次の3件

## アーキテクチャ
```
Trio.app (SwiftUI + SwiftData)
├── Connectors/
│   ├── NotificationDBReader.swift  ← LINE等の通知DB読み
│   ├── SlackConnector.swift
│   ├── ChatworkConnector.swift
│   └── iMessageReader.swift
├── Triage/
│   └── ClaudeBatcher.swift         ← Haiku 4.5でスコア+返信案生成
├── Dispatcher/
│   ├── SlackSender.swift
│   ├── ChatworkSender.swift
│   └── LINESender.swift            ← AX or clipboard半自動
├── UI/
│   ├── MenubarApp.swift
│   ├── TripleCardView.swift        ← 3件カード
│   └── ComposeEditor.swift
└── Models/ (SwiftData)
    ├── Message
    ├── ReplyDraft
    └── Account
```

## 実装ステップ
1. **[検証]** 通知DB読み取りPoCを `scripts/dump_notifications.sh` で実装、LINEメッセージが取れるか確認
2. Swift Package雛形 (`swift package init --type executable`)
3. SwiftData Schema定義 (Message, ReplyDraft, Account)
4. NotificationDBReader実装（bplistデコード含む）
5. Slack/Chatwork Connector実装
6. ClaudeBatcher実装（`/v1/messages` APIをbatchで叩く）
7. TripleCardView実装
8. Dispatcher実装
9. `swift build` → 起動 → 実データ確認

## 未解決リスク
- **通知DB権限**: macOS 14+ではFull Disk Access必要、検証でアクセス可否を確認
- **bplistフォーマット**: req カラムは bplist、plutilでデコード可か検証
- **LINE送信UX**: 自動貼付け＆Returnが不安定な場合はクリップボードコピー+通知のみで妥協
- **Claude APIキー**: 初回起動時にBYOKダイアログ

## 次アクション
- Task #1: 通知DB読み取り検証（`sqlite3` + `plutil` でLINEレコード取得）
