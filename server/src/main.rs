// Trio Cloud — Triage as a Service
// メールマジックリンク認証 → クレジット残高管理 → Anthropic APIプロキシ
//
// エンドポイント:
//   POST /v1/auth/magiclink   { email }                → メール送信
//   GET  /v1/auth/verify?t=   (Resendから)             → トークン発行
//   GET  /v1/me                                        → {email, credits}
//   POST /v1/triage           { messages: [...], system } → AI実行 + クレジット消費
//   POST /v1/checkout         { plan }                 → Stripe Checkout
//   POST /v1/sync/upload      (encrypted blob)         → E2E同期
//   GET  /v1/sync/download                             → E2E同期
//   GET  /                                             → Web UI (token=xxx)
//   POST /v1/web/state        (plain JSON)             → Mac uploads web-readable state
//   GET  /v1/web/messages?token=xxx                    → user's messages for web view
//   POST /v1/web/send         { token, message_id, reply_text } → command for Mac
//   GET  /v1/web/commands?token=xxx                    → Mac polls for pending commands

use anyhow::{Context, Result};
use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{Html, IntoResponse, Json},
    routing::{get, post},
    Router,
};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};
use tower_http::cors::{Any, CorsLayer};

// ========== State ==========

#[derive(Clone)]
struct AppState {
    db: Arc<Mutex<Connection>>,
    anthropic_key: String,
    resend_key: String,
    base_url: String,
}

fn init_db(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        r#"
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            email TEXT UNIQUE NOT NULL,
            credits INTEGER NOT NULL DEFAULT 50,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS sync_snapshots (
            user_id TEXT PRIMARY KEY,
            encrypted_blob BLOB NOT NULL,
            updated_at TEXT NOT NULL,
            size_bytes INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS magic_links (
            token TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            expires_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS api_tokens (
            token TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS usage_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT NOT NULL,
            credits_used INTEGER NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS web_state (
            user_id TEXT PRIMARY KEY,
            state_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS commands (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            reply_text TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TEXT NOT NULL
        );
        "#,
    )?;
    Ok(())
}

// ========== Auth: Magic Link ==========

#[derive(Deserialize)]
struct MagicLinkReq {
    email: String,
}

async fn magic_link(
    State(state): State<AppState>,
    Json(req): Json<MagicLinkReq>,
) -> Result<StatusCode, AppError> {
    let token = uuid::Uuid::new_v4().to_string();
    let expires = (chrono::Utc::now() + chrono::Duration::minutes(15)).to_rfc3339();
    {
        let db = state.db.lock().unwrap();
        db.execute(
            "INSERT INTO magic_links (token, email, expires_at) VALUES (?1, ?2, ?3)",
            params![token, req.email, expires],
        )?;
    }

    let verify_url = format!("{}/v1/auth/verify?t={}", state.base_url, token);
    send_email(
        &state.resend_key,
        &req.email,
        "Trio ログイン",
        &format!(
            "<p>Trio へのログインリンク (15分有効):</p>\
             <p><a href=\"{0}\">{0}</a></p>",
            verify_url
        ),
    )
    .await?;

    Ok(StatusCode::OK)
}

async fn verify(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<impl IntoResponse, AppError> {
    let token = params.get("t").ok_or(AppError::BadRequest)?;
    let db = state.db.lock().unwrap();

    let email: String = db
        .query_row(
            "SELECT email FROM magic_links WHERE token=?1 AND expires_at > ?2",
            params![token, chrono::Utc::now().to_rfc3339()],
            |row| row.get(0),
        )
        .map_err(|_| AppError::Unauthorized)?;

    db.execute("DELETE FROM magic_links WHERE token=?1", params![token])?;

    // ユーザー作成 or 取得
    let user_id: String = match db.query_row(
        "SELECT id FROM users WHERE email=?1",
        params![email],
        |row| row.get(0),
    ) {
        Ok(id) => id,
        Err(_) => {
            let id = uuid::Uuid::new_v4().to_string();
            db.execute(
                "INSERT INTO users (id, email, credits, created_at) VALUES (?1, ?2, 50, ?3)",
                params![id, email, chrono::Utc::now().to_rfc3339()],
            )?;
            id
        }
    };

    // API tokenを発行
    let api_token = format!("trio_{}", uuid::Uuid::new_v4().simple());
    db.execute(
        "INSERT INTO api_tokens (token, user_id, created_at) VALUES (?1, ?2, ?3)",
        params![api_token, user_id, chrono::Utc::now().to_rfc3339()],
    )?;

    // ブラウザ表示用の簡易ページ
    let html = format!(
        r#"<!DOCTYPE html><html><head><meta charset="utf-8"><title>Trio</title>
<style>body{{font-family:-apple-system,sans-serif;max-width:480px;margin:80px auto;padding:20px;text-align:center}}
.token{{background:#f4f4f4;padding:14px;border-radius:8px;font-family:monospace;font-size:13px;word-break:break-all;margin:20px 0}}
button{{background:#000;color:#fff;border:none;padding:10px 20px;border-radius:6px;font-size:14px;cursor:pointer}}</style></head>
<body>
<h2>✅ ログイン成功</h2>
<p>{}</p>
<p>このトークンを Trio アプリの設定にペーストしてください:</p>
<div class="token" id="t">{}</div>
<button onclick="navigator.clipboard.writeText(document.getElementById('t').textContent);this.textContent='コピー済'">コピー</button>
<p style="color:#666;font-size:12px;margin-top:30px">トークンは1回だけ表示されます</p>
<p style="margin-top:20px"><a href="/?token={}" style="color:#007AFF">Web ダッシュボードを開く →</a></p>
</body></html>"#,
        email, api_token, api_token
    );

    Ok(([("content-type", "text/html; charset=utf-8")], html))
}

// ========== Auth Middleware ==========

fn auth(state: &AppState, headers: &HeaderMap) -> Result<String, AppError> {
    let auth = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.strip_prefix("Bearer "))
        .ok_or(AppError::Unauthorized)?;

    let db = state.db.lock().unwrap();
    db.query_row(
        "SELECT user_id FROM api_tokens WHERE token=?1",
        params![auth],
        |row| row.get(0),
    )
    .map_err(|_| AppError::Unauthorized)
}

fn auth_by_token(state: &AppState, token: &str) -> Result<String, AppError> {
    let db = state.db.lock().unwrap();
    db.query_row(
        "SELECT user_id FROM api_tokens WHERE token=?1",
        params![token],
        |row| row.get(0),
    )
    .map_err(|_| AppError::Unauthorized)
}

// ========== /v1/me ==========

#[derive(Serialize)]
struct MeResp {
    email: String,
    credits: i64,
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<MeResp>, AppError> {
    let user_id = auth(&state, &headers)?;
    let db = state.db.lock().unwrap();
    let (email, credits): (String, i64) = db.query_row(
        "SELECT email, credits FROM users WHERE id=?1",
        params![user_id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok(Json(MeResp { email, credits }))
}

// ========== /v1/triage (本体) ==========

#[derive(Deserialize)]
struct TriageReq {
    messages: Vec<serde_json::Value>,
    system: String,
}

#[derive(Serialize)]
struct TriageResp {
    results: serde_json::Value,
    credits_used: i64,
    credits_left: i64,
}

async fn triage(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TriageReq>,
) -> Result<Json<TriageResp>, AppError> {
    let user_id = auth(&state, &headers)?;

    // 1メッセージ=1クレジット (バッチ単位)
    let cost = req.messages.len().max(1) as i64;

    // クレジット確認 + 消費
    {
        let db = state.db.lock().unwrap();
        let credits: i64 =
            db.query_row("SELECT credits FROM users WHERE id=?1", params![user_id], |r| {
                r.get(0)
            })?;
        if credits < cost {
            return Err(AppError::PaymentRequired);
        }
        db.execute(
            "UPDATE users SET credits = credits - ?1 WHERE id=?2",
            params![cost, user_id],
        )?;
        db.execute(
            "INSERT INTO usage_log (user_id, credits_used, created_at) VALUES (?1, ?2, ?3)",
            params![user_id, cost, chrono::Utc::now().to_rfc3339()],
        )?;
    }

    // Anthropic API呼び出し
    let user_text = format!(
        "未読メッセージ一覧:\n{}",
        serde_json::to_string(&req.messages).unwrap_or_default()
    );
    let anthropic_payload = serde_json::json!({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 4096,
        "system": req.system,
        "messages": [{"role": "user", "content": user_text}]
    });

    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", &state.anthropic_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&anthropic_payload)
        .send()
        .await
        .context("anthropic call failed")?;

    let body: serde_json::Value = resp.json().await.context("parse anthropic resp")?;
    let text = body
        .get("content")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("text"))
        .and_then(|t| t.as_str())
        .unwrap_or("[]")
        .replace("```json", "")
        .replace("```", "");
    let results: serde_json::Value =
        serde_json::from_str(text.trim()).unwrap_or(serde_json::json!([]));

    let credits_left: i64 = {
        let db = state.db.lock().unwrap();
        db.query_row("SELECT credits FROM users WHERE id=?1", params![user_id], |r| {
            r.get(0)
        })?
    };

    Ok(Json(TriageResp {
        results,
        credits_used: cost,
        credits_left,
    }))
}

// ========== Sync endpoints (E2E encrypted blobs) ==========

async fn sync_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<StatusCode, AppError> {
    let user_id = auth(&state, &headers)?;
    let size = body.len() as i64;
    if size > 50 * 1024 * 1024 {
        return Err(AppError::BadRequest);
    }
    let db = state.db.lock().unwrap();
    db.execute(
        "INSERT INTO sync_snapshots (user_id, encrypted_blob, updated_at, size_bytes)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(user_id) DO UPDATE SET
           encrypted_blob = excluded.encrypted_blob,
           updated_at = excluded.updated_at,
           size_bytes = excluded.size_bytes",
        params![user_id, body.to_vec(), chrono::Utc::now().to_rfc3339(), size],
    )?;
    Ok(StatusCode::OK)
}

async fn sync_download(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<axum::body::Bytes, AppError> {
    let user_id = auth(&state, &headers)?;
    let db = state.db.lock().unwrap();
    let blob: Vec<u8> = db
        .query_row(
            "SELECT encrypted_blob FROM sync_snapshots WHERE user_id = ?1",
            params![user_id],
            |row| row.get(0),
        )
        .map_err(|_| AppError::Unauthorized)?;
    Ok(axum::body::Bytes::from(blob))
}

// ========== Web UI & Web API ==========

/// GET / — Web dashboard (requires ?token=xxx query param)
async fn web_dashboard(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<impl IntoResponse, AppError> {
    let token = match params.get("token") {
        Some(t) => t.clone(),
        None => return Ok(Html(WEB_LOGIN_HTML.to_string()).into_response()),
    };

    // Validate token
    let _user_id = auth_by_token(&state, &token)?;

    // Return the web dashboard HTML with token embedded
    let html = WEB_DASHBOARD_HTML.replace("__TOKEN__", &token);
    Ok(Html(html).into_response())
}

/// POST /v1/web/state — Mac uploads plain JSON state for web viewing
#[derive(Deserialize)]
struct WebStateReq {
    messages: Vec<serde_json::Value>,
}

async fn web_state_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<WebStateReq>,
) -> Result<StatusCode, AppError> {
    let user_id = auth(&state, &headers)?;
    let json_str = serde_json::to_string(&req.messages).unwrap_or_else(|_| "[]".into());
    let db = state.db.lock().unwrap();
    db.execute(
        "INSERT INTO web_state (user_id, state_json, updated_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(user_id) DO UPDATE SET
           state_json = excluded.state_json,
           updated_at = excluded.updated_at",
        params![user_id, json_str, chrono::Utc::now().to_rfc3339()],
    )?;
    Ok(StatusCode::OK)
}

/// GET /v1/web/messages?token=xxx — Returns user's messages for web view
async fn web_messages(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Json<WebMessagesResp>, AppError> {
    let token = params.get("token").ok_or(AppError::Unauthorized)?;
    let user_id = auth_by_token(&state, token)?;
    let db = state.db.lock().unwrap();

    let state_json: String = db
        .query_row(
            "SELECT state_json FROM web_state WHERE user_id = ?1",
            params![user_id],
            |row| row.get(0),
        )
        .unwrap_or_else(|_| "[]".into());

    let updated_at: String = db
        .query_row(
            "SELECT updated_at FROM web_state WHERE user_id = ?1",
            params![user_id],
            |row| row.get(0),
        )
        .unwrap_or_else(|_| "".into());

    let messages: Vec<serde_json::Value> =
        serde_json::from_str(&state_json).unwrap_or_default();

    Ok(Json(WebMessagesResp {
        messages,
        updated_at,
    }))
}

#[derive(Serialize)]
struct WebMessagesResp {
    messages: Vec<serde_json::Value>,
    updated_at: String,
}

/// POST /v1/web/send — Create a command for Mac to execute
#[derive(Deserialize)]
struct WebSendReq {
    token: String,
    message_id: String,
    reply_text: String,
}

#[derive(Serialize)]
struct WebSendResp {
    id: String,
    status: String,
}

async fn web_send(
    State(state): State<AppState>,
    Json(req): Json<WebSendReq>,
) -> Result<Json<WebSendResp>, AppError> {
    let user_id = auth_by_token(&state, &req.token)?;
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();

    let db = state.db.lock().unwrap();
    db.execute(
        "INSERT INTO commands (id, user_id, message_id, reply_text, status, created_at)
         VALUES (?1, ?2, ?3, ?4, 'pending', ?5)",
        params![id, user_id, req.message_id, req.reply_text, now],
    )?;

    Ok(Json(WebSendResp {
        id,
        status: "pending".into(),
    }))
}

/// GET /v1/web/commands?token=xxx — Mac polls for pending commands, marks as processing
#[derive(Serialize)]
struct CommandItem {
    id: String,
    message_id: String,
    reply_text: String,
    created_at: String,
}

#[derive(Serialize)]
struct WebCommandsResp {
    commands: Vec<CommandItem>,
}

async fn web_commands(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Result<Json<WebCommandsResp>, AppError> {
    let token = params.get("token").ok_or(AppError::Unauthorized)?;
    let user_id = auth_by_token(&state, token)?;
    let db = state.db.lock().unwrap();

    let mut stmt = db.prepare(
        "SELECT id, message_id, reply_text, created_at FROM commands
         WHERE user_id = ?1 AND status = 'pending'
         ORDER BY created_at ASC",
    )?;

    let commands: Vec<CommandItem> = stmt
        .query_map(params![user_id], |row| {
            Ok(CommandItem {
                id: row.get(0)?,
                message_id: row.get(1)?,
                reply_text: row.get(2)?,
                created_at: row.get(3)?,
            })
        })?
        .filter_map(|r| r.ok())
        .collect();

    // Mark all returned commands as processing
    let ids: Vec<String> = commands.iter().map(|c| c.id.clone()).collect();
    for id in &ids {
        db.execute(
            "UPDATE commands SET status = 'processing' WHERE id = ?1",
            params![id],
        )?;
    }

    Ok(Json(WebCommandsResp { commands }))
}

// ========== Web UI HTML ==========

const WEB_LOGIN_HTML: &str = r##"<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Trio — AIメッセージアシスタント</title>
<meta property="og:title" content="Trio — AIメッセージアシスタント">
<meta property="og:description" content="LINE / Discord / iMessage / Slack を横断取得。Claude AIが重要度判定+返信案を自動生成。3クリックで全メッセージに返信。">
<meta property="og:image" content="https://raw.githubusercontent.com/yukihamada/trio/master/ogp.png">
<meta property="og:url" content="https://trio-cloud.fly.dev/">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Trio">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="Trio — AIメッセージアシスタント">
<meta name="twitter:description" content="LINE/Discord/iMessage/Slackを横断。AIが返信案を自動生成。macOS + Web対応。">
<meta name="twitter:image" content="https://raw.githubusercontent.com/yukihamada/trio/master/ogp.png">
<meta name="description" content="LINE / Discord / iMessage / Slack を横断取得。Claude AIが重要度判定+返信案を自動生成。Apple公証済みmacOSアプリ。">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📥</text></svg>">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0a0a0a;color:#e5e5e5;min-height:100vh}
.hero{text-align:center;padding:60px 24px 40px;max-width:640px;margin:0 auto}
.logo{display:inline-flex;align-items:center;justify-content:center;width:80px;height:80px;background:linear-gradient(135deg,#3b82f6,#8b5cf6);border-radius:22px;margin-bottom:24px;box-shadow:0 20px 40px rgba(59,130,246,0.3)}
.logo span{font-size:40px}
h1{font-size:36px;font-weight:800;margin-bottom:12px;letter-spacing:-0.02em;background:linear-gradient(135deg,#60a5fa,#a78bfa);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.tagline{color:#a3a3a3;font-size:18px;margin-bottom:12px;line-height:1.5}
.badges{display:flex;gap:8px;justify-content:center;flex-wrap:wrap;margin-bottom:40px}
.badge{padding:4px 12px;border-radius:20px;font-size:12px;font-weight:600;border:1px solid #333}
.badge.green{color:#22c55e;border-color:#22c55e33;background:#22c55e11}
.badge.blue{color:#3b82f6;border-color:#3b82f633;background:#3b82f611}
.badge.purple{color:#a78bfa;border-color:#a78bfa33;background:#a78bfa11}

.dl-section{background:#111;border:1px solid #262626;border-radius:16px;padding:28px;margin-bottom:32px;text-align:center}
.dl-section h2{font-size:18px;font-weight:700;margin-bottom:8px}
.dl-section p{font-size:13px;color:#737373;margin-bottom:16px}
.dl-btn{display:inline-flex;align-items:center;gap:10px;padding:14px 28px;border-radius:12px;background:linear-gradient(135deg,#3b82f6,#6366f1);color:#fff;font-size:16px;font-weight:700;text-decoration:none;transition:transform .15s}
.dl-btn:active{transform:scale(0.97)}
.dl-btn .icon{font-size:22px}
.dl-info{font-size:11px;color:#525252;margin-top:12px}

.features{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:32px;text-align:left}
@media(max-width:500px){.features{grid-template-columns:1fr}}
.feat{background:#111;border:1px solid #1a1a1a;border-radius:12px;padding:16px}
.feat .icon{font-size:20px;margin-bottom:8px}
.feat h3{font-size:14px;font-weight:700;margin-bottom:4px}
.feat p{font-size:12px;color:#737373;line-height:1.4}

.login-section{background:#111;border:1px solid #262626;border-radius:16px;padding:24px;margin-bottom:32px}
.login-section h2{font-size:16px;font-weight:700;margin-bottom:4px}
.login-section .sub{font-size:12px;color:#737373;margin-bottom:16px}
.input-wrap{margin-bottom:12px}
input[type=email]{width:100%;padding:12px 16px;border-radius:10px;border:1px solid #262626;background:#0a0a0a;color:#e5e5e5;font-size:15px;outline:none}
input[type=email]:focus{border-color:#3b82f6}
.login-btn{width:100%;padding:12px;border-radius:10px;border:none;background:#3b82f6;color:#fff;font-size:15px;font-weight:600;cursor:pointer}
.login-btn:active{background:#2563eb}
.msg{margin-top:12px;font-size:13px;color:#737373}

.footer{text-align:center;padding:20px;font-size:11px;color:#404040}
.footer a{color:#525252;text-decoration:none}
</style>
</head>
<body>
<div class="hero">

<div class="logo"><span>📥</span></div>
<h1>Trio</h1>
<p class="tagline">LINE / Discord / iMessage / Slack<br>全メッセージをAIが整理、3クリックで返信</p>
<div class="badges">
  <span class="badge green">✅ Apple公証済み</span>
  <span class="badge blue">🤖 Claude AI搭載</span>
  <span class="badge purple">🔒 E2E暗号化</span>
</div>

<!-- ダウンロード -->
<div class="dl-section">
  <h2>macOS アプリをダウンロード</h2>
  <p>Developer ID署名 + Apple公証済みで安全</p>
  <a href="https://github.com/yukihamada/trio/releases/latest/download/Trio-0.1.0.pkg" class="dl-btn">
    <span class="icon">⬇️</span> Trio をインストール (.pkg)
  </a>
  <p class="dl-info">ワンクリックで /Applications にインストール · macOS 14+ · 2.1MB<br>Developer ID署名 + Apple公証済み · Yuki Hamada (5BV85JW8US)</p>
  <p style="margin-top:8px"><a href="https://github.com/yukihamada/trio/releases/latest/download/Trio-0.1.0.dmg" style="color:#525252;font-size:11px;text-decoration:underline">DMG版はこちら</a></p>
</div>

<!-- 機能一覧 -->
<div class="features">
  <div class="feat"><div class="icon">💬</div><h3>LINE OCR対応</h3><p>業界初。LINEの画面をAI OCRで読み取り</p></div>
  <div class="feat"><div class="icon">🤖</div><h3>AI返信案 8-10パターン</h3><p>承諾/辞退/質問/保留/カジュアル等</p></div>
  <div class="feat"><div class="icon">📱</div><h3>スマホから操作</h3><p>Webダッシュボードで外出先から返信</p></div>
  <div class="feat"><div class="icon">⚡</div><h3>ワンクリック送信</h3><p>選んで送るだけ。3秒で1件処理</p></div>
  <div class="feat"><div class="icon">🧠</div><h3>文体学習</h3><p>使うほどあなたらしい返信を提案</p></div>
  <div class="feat"><div class="icon">🔒</div><h3>プライバシー重視</h3><p>AES-256暗号化、データはローカル優先</p></div>
</div>

<!-- ログイン (既にアプリを持っている人向け) -->
<div class="login-section">
  <h2>📱 Web ダッシュボード</h2>
  <p class="sub">Mac の Trio アプリ設定済みの方はメールでログイン</p>
  <div class="input-wrap"><input type="email" id="email" placeholder="you@example.com" autocomplete="email"></div>
  <button class="login-btn" onclick="doLogin()">マジックリンクを送信</button>
  <p class="msg" id="msg"></p>
</div>

<div class="footer">
  <a href="https://github.com/yukihamada/trio">GitHub</a> ·
  <a href="https://github.com/yukihamada/trio/blob/master/legal/privacy.md">プライバシー</a> ·
  <a href="https://github.com/yukihamada/trio/blob/master/legal/terms.md">利用規約</a>
  <br>© 2026 Yuki Hamada
</div>

</div>
<script>
async function doLogin(){
  const email=document.getElementById('email').value.trim();
  if(!email){document.getElementById('msg').textContent='メールアドレスを入力してください';return}
  document.getElementById('msg').textContent='送信中...';
  try{
    const r=await fetch('/v1/auth/magiclink',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email})});
    document.getElementById('msg').textContent=r.ok?'✅ メールを確認してください（リンクをクリック）':'❌ エラー: '+r.statusText;
  }catch(e){document.getElementById('msg').textContent='❌ ネットワークエラー'}
}
</script>
</body>
</html>"##;

const WEB_DASHBOARD_HTML: &str = r##"<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>Trio — Messages</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#0a0a0a;--card:#171717;--border:#262626;--text:#e5e5e5;--muted:#737373;--blue:#3b82f6;--red:#ef4444;--yellow:#eab308;--green:#22c55e;--purple:#a78bfa}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;padding-bottom:env(safe-area-inset-bottom)}
.header{position:sticky;top:0;z-index:10;background:rgba(10,10,10,0.85);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);padding:16px 16px 12px;border-bottom:1px solid var(--border)}
.header h1{font-size:20px;font-weight:700;margin-bottom:4px}
.header .meta{font-size:12px;color:var(--muted)}
.filters{display:flex;gap:8px;padding:12px 16px;overflow-x:auto;-webkit-overflow-scrolling:touch}
.filters::-webkit-scrollbar{display:none}
.chip{flex-shrink:0;padding:6px 14px;border-radius:20px;border:1px solid var(--border);background:var(--card);color:var(--muted);font-size:13px;cursor:pointer;transition:all .15s}
.chip.active{background:var(--blue);color:#fff;border-color:var(--blue)}
.messages{padding:8px 16px 100px}
.msg-card{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:14px;margin-bottom:10px;transition:opacity .15s}
.msg-card.sent{opacity:0.5}
.msg-top{display:flex;justify-content:space-between;align-items:center;margin-bottom:6px}
.msg-sender{font-weight:600;font-size:14px}
.msg-service{font-size:11px;color:var(--muted);background:var(--bg);padding:2px 8px;border-radius:10px}
.msg-body{font-size:14px;line-height:1.5;margin-bottom:10px;word-break:break-word}
.msg-time{font-size:11px;color:var(--muted);margin-bottom:8px}
.priority-badge{display:inline-block;font-size:11px;font-weight:600;padding:2px 8px;border-radius:10px;margin-right:6px}
.priority-urgent{background:rgba(239,68,68,0.15);color:var(--red)}
.priority-high{background:rgba(234,179,8,0.15);color:var(--yellow)}
.priority-normal{background:rgba(34,197,94,0.15);color:var(--green)}
.priority-low{background:rgba(115,115,115,0.15);color:var(--muted)}
.reply-options{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
.reply-btn{padding:8px 14px;border-radius:10px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:13px;cursor:pointer;transition:all .15s}
.reply-btn:active{background:var(--blue);color:#fff;border-color:var(--blue)}
.reply-btn.sending{opacity:0.5;pointer-events:none}
.custom-reply{display:flex;gap:6px;margin-top:8px}
.custom-reply input{flex:1;padding:10px 14px;border-radius:10px;border:1px solid var(--border);background:var(--bg);color:var(--text);font-size:14px;outline:none}
.custom-reply input:focus{border-color:var(--blue)}
.custom-reply button{padding:10px 16px;border-radius:10px;border:none;background:var(--blue);color:#fff;font-size:14px;font-weight:600;cursor:pointer;flex-shrink:0}
.custom-reply button:active{background:#2563eb}
.empty{text-align:center;padding:80px 20px;color:var(--muted)}
.empty .icon{font-size:48px;margin-bottom:16px}
.empty p{font-size:15px}
.status-bar{position:fixed;bottom:0;left:0;right:0;background:rgba(10,10,10,0.9);backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);border-top:1px solid var(--border);padding:12px 16px;padding-bottom:calc(12px + env(safe-area-inset-bottom));display:flex;justify-content:space-between;align-items:center;font-size:12px;color:var(--muted)}
.status-dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px}
.status-dot.online{background:var(--green)}
.status-dot.offline{background:var(--red)}
.toast{position:fixed;top:20px;left:50%;transform:translateX(-50%);background:#22c55e;color:#fff;padding:10px 20px;border-radius:10px;font-size:14px;font-weight:600;opacity:0;transition:opacity .3s;pointer-events:none;z-index:100}
.toast.show{opacity:1}
@media(prefers-color-scheme:light){
  :root{--bg:#f5f5f5;--card:#fff;--border:#e5e5e5;--text:#171717;--muted:#737373}
}
</style>
</head>
<body>

<div class="header">
  <h1>Trio</h1>
  <div class="meta">Last sync: <span id="last-sync">--</span></div>
</div>

<div class="filters" id="filters">
  <div class="chip active" data-filter="all" onclick="setFilter('all')">All</div>
  <div class="chip" data-filter="urgent" onclick="setFilter('urgent')">Urgent</div>
  <div class="chip" data-filter="high" onclick="setFilter('high')">High</div>
  <div class="chip" data-filter="unread" onclick="setFilter('unread')">Unread</div>
</div>

<div class="messages" id="messages">
  <div class="empty" id="empty-state">
    <div class="icon">📭</div>
    <p>No messages yet</p>
    <p style="font-size:13px;margin-top:8px">Enable "Web Access" in Trio.app settings,<br>then messages will appear here.</p>
  </div>
</div>

<div class="status-bar">
  <div><span class="status-dot" id="status-dot"></span><span id="status-text">Connecting...</span></div>
  <div id="msg-count">0 messages</div>
</div>

<div class="toast" id="toast"></div>

<script>
const TOKEN='__TOKEN__';
let currentFilter='all';
let allMessages=[];
let sentCommands=new Set();

function showToast(msg){
  const t=document.getElementById('toast');
  t.textContent=msg;
  t.classList.add('show');
  setTimeout(()=>t.classList.remove('show'),2000);
}

function setFilter(f){
  currentFilter=f;
  document.querySelectorAll('.chip').forEach(c=>c.classList.toggle('active',c.dataset.filter===f));
  renderMessages();
}

function priorityClass(p){
  if(!p) return 'normal';
  const lp=p.toLowerCase();
  if(lp==='urgent'||lp==='critical') return 'urgent';
  if(lp==='high') return 'high';
  if(lp==='low') return 'low';
  return 'normal';
}

function timeAgo(dateStr){
  if(!dateStr) return '';
  try{
    const d=new Date(dateStr);
    const now=new Date();
    const diff=Math.floor((now-d)/1000);
    if(diff<60) return 'just now';
    if(diff<3600) return Math.floor(diff/60)+'m ago';
    if(diff<86400) return Math.floor(diff/3600)+'h ago';
    return Math.floor(diff/86400)+'d ago';
  }catch(e){return dateStr}
}

function getReplyOptions(msg){
  // Generate contextual reply options based on message content
  if(msg.suggested_replies && msg.suggested_replies.length>0) return msg.suggested_replies;
  const options=[];
  const body=(msg.body||msg.content||'').toLowerCase();
  if(body.includes('?')||body.includes('？')){
    options.push('Yes','No','Let me check');
  }
  if(body.includes('meeting')||body.includes('ミーティング')||body.includes('schedule')){
    options.push('OK','Reschedule','Decline');
  }
  if(body.includes('review')||body.includes('確認')){
    options.push('Approved','Will review','Need changes');
  }
  if(options.length===0) options.push('OK','Thanks','Will do');
  return options;
}

function renderMessages(){
  const container=document.getElementById('messages');
  const emptyState=document.getElementById('empty-state');
  let filtered=allMessages;
  if(currentFilter==='urgent') filtered=allMessages.filter(m=>priorityClass(m.priority)==='urgent');
  else if(currentFilter==='high') filtered=allMessages.filter(m=>priorityClass(m.priority)==='high'||priorityClass(m.priority)==='urgent');
  else if(currentFilter==='unread') filtered=allMessages.filter(m=>!m.is_read);

  if(filtered.length===0){
    emptyState.style.display='block';
    container.innerHTML='';
    container.appendChild(emptyState);
    document.getElementById('msg-count').textContent='0 messages';
    return;
  }

  emptyState.style.display='none';
  document.getElementById('msg-count').textContent=filtered.length+' message'+(filtered.length!==1?'s':'');

  const html=filtered.map((msg,i)=>{
    const pc=priorityClass(msg.priority);
    const msgId=msg.id||msg.message_id||('msg-'+i);
    const isSent=sentCommands.has(msgId);
    const replies=getReplyOptions(msg);
    const replyBtns=replies.map(r=>`<button class="reply-btn${isSent?' sending':''}" onclick="sendReply('${msgId}','${r.replace(/'/g,"\\'")}',this)"${isSent?' disabled':''}>${isSent?'Sent':r}</button>`).join('');

    return `<div class="msg-card${isSent?' sent':''}" id="card-${msgId}">
      <div class="msg-top">
        <span class="msg-sender">${escHtml(msg.sender||msg.from||'Unknown')}</span>
        <span class="msg-service">${escHtml(msg.service||msg.app||'')}</span>
      </div>
      ${msg.subject?`<div style="font-weight:600;font-size:14px;margin-bottom:4px">${escHtml(msg.subject)}</div>`:''}
      <div class="msg-body">${escHtml(msg.body||msg.content||msg.text||'')}</div>
      <div class="msg-time">
        <span class="priority-badge priority-${pc}">${pc.toUpperCase()}</span>
        ${timeAgo(msg.date||msg.timestamp||msg.received_at)}
      </div>
      <div class="reply-options">${replyBtns}</div>
      <div class="custom-reply">
        <input type="text" placeholder="Custom reply..." id="input-${msgId}" onkeydown="if(event.key==='Enter')sendCustomReply('${msgId}')">
        <button onclick="sendCustomReply('${msgId}')">Send</button>
      </div>
    </div>`;
  }).join('');

  container.innerHTML=html;
}

function escHtml(s){
  if(!s) return '';
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

async function sendReply(msgId,text,btn){
  if(btn) btn.classList.add('sending');
  try{
    const r=await fetch('/v1/web/send',{
      method:'POST',
      headers:{'content-type':'application/json'},
      body:JSON.stringify({token:TOKEN,message_id:msgId,reply_text:text})
    });
    if(r.ok){
      sentCommands.add(msgId);
      showToast('Reply queued');
      renderMessages();
    }else{
      showToast('Error: '+r.statusText);
      if(btn) btn.classList.remove('sending');
    }
  }catch(e){
    showToast('Network error');
    if(btn) btn.classList.remove('sending');
  }
}

function sendCustomReply(msgId){
  const input=document.getElementById('input-'+msgId);
  if(!input||!input.value.trim()) return;
  sendReply(msgId,input.value.trim(),null);
  input.value='';
}

async function fetchMessages(){
  try{
    const r=await fetch('/v1/web/messages?token='+TOKEN);
    if(!r.ok){
      if(r.status===401) window.location.href='/';
      return;
    }
    const data=await r.json();
    allMessages=data.messages||[];

    // Build filter chips dynamically from services
    const services=new Set();
    allMessages.forEach(m=>{if(m.service||m.app) services.add(m.service||m.app)});
    const filtersEl=document.getElementById('filters');
    // Keep default chips, add service chips
    const defaultChips=filtersEl.querySelectorAll('.chip[data-filter]');
    const existingFilters=new Set();
    defaultChips.forEach(c=>existingFilters.add(c.dataset.filter));
    services.forEach(s=>{
      const key='svc-'+s.toLowerCase().replace(/\s+/g,'-');
      if(!existingFilters.has(key)){
        const chip=document.createElement('div');
        chip.className='chip';
        chip.dataset.filter=key;
        chip.textContent=s;
        chip.onclick=()=>{
          currentFilter=key;
          document.querySelectorAll('.chip').forEach(c=>c.classList.toggle('active',c.dataset.filter===key));
          allMessages=data.messages.filter(m=>(m.service||m.app||'').toLowerCase().replace(/\s+/g,'-')===s.toLowerCase().replace(/\s+/g,'-'));
          renderMessages();
          allMessages=data.messages; // restore
        };
        filtersEl.appendChild(chip);
        existingFilters.add(key);
      }
    });

    if(data.updated_at){
      document.getElementById('last-sync').textContent=timeAgo(data.updated_at);
    }
    document.getElementById('status-dot').classList.add('online');
    document.getElementById('status-dot').classList.remove('offline');
    document.getElementById('status-text').textContent='Connected';
    renderMessages();
  }catch(e){
    document.getElementById('status-dot').classList.add('offline');
    document.getElementById('status-dot').classList.remove('online');
    document.getElementById('status-text').textContent='Offline';
  }
}

// Initial fetch + auto-refresh every 10s
fetchMessages();
setInterval(fetchMessages,10000);
</script>
</body>
</html>"##;

// ========== Email (Resend) ==========

async fn send_email(api_key: &str, to: &str, subject: &str, html: &str) -> Result<()> {
    let client = reqwest::Client::new();
    let resp = client
        .post("https://api.resend.com/emails")
        .bearer_auth(api_key)
        .json(&serde_json::json!({
            "from": "Trio <noreply@trio.ai>",
            "to": to,
            "subject": subject,
            "html": html,
        }))
        .send()
        .await?;
    if !resp.status().is_success() {
        let txt = resp.text().await.unwrap_or_default();
        anyhow::bail!("resend error: {}", txt);
    }
    Ok(())
}

// ========== Errors ==========

enum AppError {
    BadRequest,
    Unauthorized,
    PaymentRequired,
    Internal(anyhow::Error),
}

impl From<anyhow::Error> for AppError {
    fn from(e: anyhow::Error) -> Self {
        AppError::Internal(e)
    }
}
impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        AppError::Internal(e.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        let (status, body) = match self {
            AppError::BadRequest => (StatusCode::BAD_REQUEST, "bad request"),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            AppError::PaymentRequired => (StatusCode::PAYMENT_REQUIRED, "out of credits"),
            AppError::Internal(e) => {
                tracing::error!("{e:?}");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
            }
        };
        (status, body).into_response()
    }
}

// ========== Main ==========

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let db_path = std::env::var("DB_PATH").unwrap_or_else(|_| "/data/trio.db".into());
    let conn = Connection::open(&db_path)?;
    init_db(&conn)?;

    let state = AppState {
        db: Arc::new(Mutex::new(conn)),
        anthropic_key: std::env::var("ANTHROPIC_API_KEY").context("ANTHROPIC_API_KEY required")?,
        resend_key: std::env::var("RESEND_API_KEY").unwrap_or_default(),
        base_url: std::env::var("BASE_URL").unwrap_or_else(|_| "http://localhost:8080".into()),
    };

    let app = Router::new()
        .route("/", get(web_dashboard))
        .route("/v1/auth/magiclink", post(magic_link))
        .route("/v1/auth/verify", get(verify))
        .route("/v1/me", get(me))
        .route("/v1/triage", post(triage))
        .route("/v1/sync/upload", post(sync_upload))
        .route("/v1/sync/download", get(sync_download))
        .route("/v1/web/state", post(web_state_upload))
        .route("/v1/web/messages", get(web_messages))
        .route("/v1/web/send", post(web_send))
        .route("/v1/web/commands", get(web_commands))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .with_state(state);

    let port: u16 = std::env::var("PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(8080);
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    tracing::info!("Trio Cloud listening on :{}", port);
    axum::serve(listener, app).await?;
    Ok(())
}
