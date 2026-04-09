import Foundation
import Network
import AppKit

/// Trio 内蔵 Web サーバ (NWListener ベース)
/// スマホから http://<mac-ip>:8787 でアクセス
final class WebServer: @unchecked Sendable {
    static let shared = WebServer()
    let port: UInt16 = 8787
    private var listener: NWListener?

    var localURL: String {
        "http://localhost:\(port)"
    }

    var lanURL: String? {
        guard let ip = Self.getWiFiAddress() else { return nil }
        return "http://\(ip):\(port)"
    }

    func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.start(queue: .global(qos: .userInitiated))
            tlog("[web] server started on :\(port)")
            if let url = lanURL {
                tlog("[web] LAN: \(url)")
            }
        } catch {
            tlog("[web] failed to start: \(error)")
        }
    }

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let response = self?.route(request: request) ?? Self.response(status: 500, body: "error")
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    /// 認証トークン (起動時にファイルから読み込み)
    private lazy var authToken: String = {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Trio/.web_token")
        return (try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }()

    /// リクエストの認証チェック (token パラメータ or Authorization ヘッダー)
    private func isAuthorized(request: String) -> Bool {
        guard !authToken.isEmpty else { return false }
        // URLパラメータ ?token=xxx
        if request.contains("token=\(authToken)") { return true }
        // Authorization: Bearer xxx
        if request.contains("Bearer \(authToken)") { return true }
        // Cookie: trio_token=xxx
        if request.contains("trio_token=\(authToken)") { return true }
        return false
    }

    /// レート制限 (IP単位で1分10リクエストまで)
    private var requestCounts: [String: (count: Int, resetAt: Date)] = [:]
    private func isRateLimited() -> Bool {
        let now = Date()
        let key = "local"  // ローカルサーバなのでIP区別不要
        var entry = requestCounts[key] ?? (count: 0, resetAt: now.addingTimeInterval(60))
        if now > entry.resetAt {
            entry = (count: 0, resetAt: now.addingTimeInterval(60))
        }
        entry.count += 1
        requestCounts[key] = entry
        return entry.count > 30  // 1分30リクエストまで
    }

    private func route(request: String) -> String {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return Self.response(status: 400, body: "bad request") }
        let method = String(parts[0])
        let path = String(parts[1])

        // ログイン画面とトークン検証は認証不要
        if method == "GET" && (path == "/" || path.hasPrefix("/?")) && !path.contains("token=") {
            return Self.response(status: 200, body: loginPageHTML(), contentType: "text/html; charset=utf-8")
        }

        // 認証チェック
        guard isAuthorized(request: request) else {
            return Self.response(status: 401, body: "{\"error\":\"unauthorized\"}", contentType: "application/json")
        }

        // レート制限
        if isRateLimited() {
            return Self.response(status: 429, body: "{\"error\":\"rate limited\"}", contentType: "application/json")
        }

        switch (method, path) {
        case ("GET", _) where path.hasPrefix("/?token=") || path.hasPrefix("/?t="):
            // 認証済みトップページ → セッションCookie設定してリダイレクト
            let html = Self.indexHTML().replacingOccurrences(
                of: "const TOKEN=''",
                with: "const TOKEN='\(authToken)'"
            )
            return Self.response(status: 200, body: html, contentType: "text/html; charset=utf-8",
                                 extraHeaders: "Set-Cookie: trio_token=\(authToken); Path=/; HttpOnly; SameSite=Strict\r\n")
        case ("GET", "/api/messages"):
            return messagesJSON()
        case ("POST", "/api/send"):
            return handleSend(request: request)
        case ("POST", "/api/skip"):
            return handleSkip(request: request)
        case ("POST", "/api/refresh"):
            handleRefresh()
            return Self.response(status: 200, body: "{\"ok\":true}", contentType: "application/json")
        default:
            return Self.response(status: 404, body: "not found")
        }
    }

    private func messagesJSON() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Trio/state.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [String: Any] else {
            return Self.response(status: 200, body: "[]", contentType: "application/json")
        }
        // メッセージをスコア降順でソート
        let sorted = messages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["importanceScore"] as? Double ?? 0) > ($1["importanceScore"] as? Double ?? 0) }
        guard let json = try? JSONSerialization.data(withJSONObject: sorted),
              let str = String(data: json, encoding: .utf8) else {
            return Self.response(status: 200, body: "[]", contentType: "application/json")
        }
        return Self.response(status: 200, body: str, contentType: "application/json")
    }

    static func response(status: Int, body: String, contentType: String = "text/plain", extraHeaders: String = "") -> String {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 401: statusText = "Unauthorized"
        case 429: statusText = "Too Many Requests"
        default: statusText = "Error"
        }
        return """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        \(extraHeaders)Connection: close\r
        \r
        \(body)
        """
    }

    /// ログインページ (トークン入力画面)
    private func loginPageHTML() -> String {
        return """
        <!DOCTYPE html><html lang="ja"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <title>Trio — ログイン</title>
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        body{font-family:-apple-system,sans-serif;background:#0a0a0a;color:#e5e5e5;min-height:100vh;display:flex;align-items:center;justify-content:center}
        .box{text-align:center;padding:40px 24px;max-width:420px;width:100%}
        h1{font-size:28px;font-weight:800;margin-bottom:8px}
        .sub{color:#737373;font-size:13px;margin-bottom:24px}
        input{width:100%;padding:14px;border-radius:10px;border:1px solid #262626;background:#171717;color:#e5e5e5;font-size:15px;margin-bottom:12px;font-family:monospace}
        button{width:100%;padding:14px;border-radius:10px;border:none;background:#3b82f6;color:#fff;font-size:15px;font-weight:600;cursor:pointer}
        .hint{font-size:11px;color:#525252;margin-top:16px;line-height:1.6}
        </style></head><body>
        <div class="box">
        <div style="font-size:48px;margin-bottom:12px">🔒</div>
        <h1>Trio</h1>
        <p class="sub">アクセスにはトークンが必要です</p>
        <input id="t" placeholder="トークンを入力" autocomplete="off">
        <button onclick="location.href='/?token='+document.getElementById('t').value">ログイン</button>
        <p class="hint">トークンは Trio Mac アプリの設定 → クラウド同期セクションで確認できます。<br>または Trio.app の 🌐 ボタンから自動ログインできます。</p>
        </div></body></html>
        """
    }

    static func getWiFiAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            guard (flags & (IFF_UP|IFF_RUNNING)) != 0, addr.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: hostname)
                }
            }
        }
        return nil
    }

    // MARK: - Actions (WebからMacを操作)

    /// AppStore参照 (メインスレッドから)
    var appStore: AppStore? = nil

    private func extractJSON(from request: String) -> [String: Any]? {
        guard let bodyStart = request.range(of: "\r\n\r\n") else { return nil }
        let body = String(request[bodyStart.upperBound...])
        guard let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func handleSend(request: String) -> String {
        guard let json = extractJSON(from: request),
              let messageId = json["messageId"] as? String,
              let replyText = json["replyText"] as? String else {
            return Self.response(status: 400, body: "{\"error\":\"messageId and replyText required\"}", contentType: "application/json")
        }
        let draftIndex = json["draftIndex"] as? Int ?? 0

        // メインスレッドで送信を実行
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.appStore,
                  let message = store.messages.first(where: { $0.id == messageId }) else { return }
            Task { @MainActor in
                await store.send(message: message, draftIndex: draftIndex, overrideText: replyText, fromWeb: true)
            }
        }
        return Self.response(status: 200, body: "{\"ok\":true,\"action\":\"sending\"}", contentType: "application/json")
    }

    private func handleSkip(request: String) -> String {
        guard let json = extractJSON(from: request),
              let messageId = json["messageId"] as? String else {
            return Self.response(status: 400, body: "{\"error\":\"messageId required\"}", contentType: "application/json")
        }
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.appStore,
                  let message = store.messages.first(where: { $0.id == messageId }) else { return }
            store.skip(message: message)
        }
        return Self.response(status: 200, body: "{\"ok\":true,\"action\":\"skipped\"}", contentType: "application/json")
    }

    private func handleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let store = self?.appStore else { return }
            Task { @MainActor in
                await store.refresh()
            }
        }
    }

    // MARK: - HTML

    static func indexHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <title>Trio</title>
        <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family:-apple-system,sans-serif; background:#0E1017; color:#f5f5f7; min-height:100vh; }
        .header { padding:16px 20px; background:#18202A; border-bottom:1px solid #ffffff12;
                   display:flex; align-items:center; gap:12px; position:sticky; top:0; z-index:10; }
        .header h1 { font-size:20px; font-weight:800; letter-spacing:-0.02em; }
        .header .badge { background:#528EFF22; color:#528EFF; padding:2px 8px; border-radius:10px; font-size:11px; font-weight:700; }
        .cards { padding:12px; display:flex; flex-direction:column; gap:10px; }
        .card { background:#18202A; border:1px solid #ffffff12; border-radius:12px; overflow:hidden; }
        .card-priority { width:4px; }
        .card-inner { padding:14px; }
        .card-header { display:flex; align-items:center; gap:8px; margin-bottom:8px; }
        .avatar { width:36px; height:36px; border-radius:50%; display:flex; align-items:center; justify-content:center;
                   font-weight:800; font-size:13px; color:#fff; }
        .sender { font-weight:700; font-size:14px; }
        .svc-badge { font-size:9px; font-weight:600; padding:2px 6px; border-radius:3px; }
        .time { font-size:10px; color:#ffffff60; margin-left:auto; }
        .body { font-size:13px; color:#ffffffcc; padding:8px; background:#ffffff06; border-radius:6px; margin-bottom:8px; }
        .reason { font-size:11px; color:#ff9500; margin-bottom:10px; }
        .replies { display:flex; flex-direction:column; gap:6px; }
        .reply-row { display:flex; align-items:center; gap:8px; padding:8px; border-radius:8px;
                     border:1px solid #ffffff15; cursor:pointer; transition:background 0.15s; }
        .reply-row:active { background:#528EFF22; }
        .tone-icon { width:32px; height:32px; border-radius:6px; display:flex; align-items:center; justify-content:center;
                     font-size:11px; font-weight:800; flex-shrink:0; }
        .reply-text { font-size:12px; flex:1; }
        .send-btn { background:#528EFF; color:#fff; border:none; padding:10px 16px; border-radius:8px;
                    font-size:13px; font-weight:700; cursor:pointer; flex-shrink:0; min-width:60px; }
        .send-btn:active { transform:scale(0.93); opacity:0.8; }
        .quick-send { display:flex; align-items:center; gap:10px; padding:14px; margin:8px 0;
                       background:linear-gradient(135deg,#22c55e,#16a34a); border-radius:12px;
                       cursor:pointer; transition:transform .1s; border:none; width:100%; color:#fff; text-align:left; }
        .quick-send:active { transform:scale(0.97); }
        .quick-send .qs-icon { font-size:22px; }
        .quick-send .qs-text { flex:1; font-size:13px; font-weight:600; line-height:1.3; }
        .quick-send .qs-label { font-size:10px; opacity:0.7; }
        .skip-btn { background:transparent; border:1px solid #333; color:#666; padding:8px 14px;
                    border-radius:8px; font-size:12px; cursor:pointer; }
        .skip-btn:active { background:#333; }
        .more-btn { text-align:center; padding:8px; color:#528EFF; font-size:11px; font-weight:600; cursor:pointer; }
        .filter-bar { padding:8px 16px; display:flex; gap:6px; overflow-x:auto; white-space:nowrap; align-items:center; }
        .skip-all { background:#ff3b3022; color:#ff3b30; border:1px solid #ff3b3044; padding:6px 14px;
                     border-radius:20px; font-size:12px; font-weight:700; cursor:pointer; flex-shrink:0; }
        .skip-all:active { background:#ff3b3044; }
        .filter-chip { padding:4px 10px; border-radius:12px; font-size:11px; font-weight:600;
                       background:#ffffff08; border:1px solid #ffffff15; color:#ffffff90; cursor:pointer; }
        .filter-chip.active { background:#528EFF22; border-color:#528EFF55; color:#528EFF; }
        .loading { text-align:center; padding:40px; color:#ffffff60; }
        .score-bar { height:3px; border-radius:2px; }
        @media(prefers-color-scheme:light) {
          body { background:#f5f5f7; color:#1d1d1f; }
          .header,.card { background:#fff; border-color:#00000010; }
          .body { background:#f5f5f7; }
        }
        </style>
        </head>
        <body>
        <div class="header">
          <div style="width:32px;height:32px;background:linear-gradient(135deg,#528EFF,#3060cc);border-radius:8px;display:flex;align-items:center;justify-content:center;">
            <span style="font-size:16px;">📥</span>
          </div>
          <h1>Trio</h1>
          <span class="badge" id="count">...</span>
          <span style="font-size:10px;color:#ffffff50;margin-left:auto;" id="updated"></span>
        </div>
        <div class="filter-bar" id="filters"></div>
        <div class="cards" id="cards"><div class="loading">読み込み中...</div></div>
        <script>
        const TOKEN='';
        function authHeaders(){return {'Content-Type':'application/json','Authorization':'Bearer '+TOKEN}}
        const TONE_COLORS = {yes:'#34c759',yes_polite:'#34c759',yes_detail:'#34c759',no:'#ff3b30',no_polite:'#ff3b30',
          ask:'#ff9500',ask_detail:'#ff9500',later:'#ffcc00',detail:'#528EFF',casual:'#af52de',emoji:'#ff2d55',
          thanks:'#ff6b8a',suggest:'#f0c020',instructed:'#528EFF'};
        const TONE_LABELS = {yes:'承諾',yes_polite:'丁寧承諾',yes_detail:'詳細承諾',no:'辞退',no_polite:'代替案',
          ask:'質問',ask_detail:'詳細質問',later:'保留',detail:'詳細',casual:'カジュアル',emoji:'絵文字',
          thanks:'お礼',suggest:'提案',instructed:'指示'};

        let allMsgs = [];
        let filter = 'all';

        async function load() {
          const r = await fetch('/api/messages',{headers:authHeaders()});
          allMsgs = await r.json();
          allMsgs = allMsgs.filter(m => m.status === 'pending');
          document.getElementById('count').textContent = allMsgs.length + '件';
          document.getElementById('updated').textContent = new Date().toLocaleTimeString('ja-JP');
          buildFilters();
          render();
        }

        function buildFilters() {
          const svcs = {};
          allMsgs.forEach(m => { svcs[m.service] = (svcs[m.service]||0)+1; });
          let html = '<button class="skip-all" onclick="skipAllVisible()">全部スキップ ⏭</button>';
          html += '<div class="filter-chip active" onclick="setFilter(\\'all\\')">すべて '+allMsgs.length+'</div>';
          Object.entries(svcs).sort((a,b)=>b[1]-a[1]).forEach(([s,c]) => {
            html += '<div class="filter-chip" onclick="setFilter(\\''+s+'\\')">'+s+' '+c+'</div>';
          });
          document.getElementById('filters').innerHTML = html;
        }

        function setFilter(f) {
          filter = f;
          document.querySelectorAll('.filter-chip').forEach(el => el.classList.remove('active'));
          event.target.classList.add('active');
          render();
        }

        function render() {
          let msgs = filter === 'all' ? allMsgs : allMsgs.filter(m => m.service === filter);
          if (!msgs.length) {
            document.getElementById('cards').innerHTML = '<div class="loading">✅ Inbox Zero!</div>';
            return;
          }
          let html = '';
          msgs.forEach((m, i) => {
            const score = m.importanceScore || 0;
            const color = score >= 0.85 ? '#ff3b30' : score >= 0.65 ? '#ff9500' : score >= 0.4 ? '#ffcc00' : '#ffffff35';
            const initials = (m.sender || '?').substring(0,2);
            const drafts = m.drafts || [];
            const visibleDrafts = drafts.slice(0, 3);
            const moreDrafts = drafts.length > 3 ? drafts.length - 3 : 0;

            html += '<div class="card"><div style="display:flex;"><div class="card-priority" style="background:'+color+';"></div><div class="card-inner" style="flex:1;">';
            html += '<div class="card-header">';
            html += '<div class="avatar" style="background:'+color+'33;border:1.5px solid '+color+';">'+initials+'</div>';
            html += '<div><div class="sender">'+esc(m.sender)+'</div>';
            html += '<span class="svc-badge" style="background:'+color+'22;color:'+color+';">'+esc(m.service)+'</span></div>';
            html += '<div class="time">'+timeAgo(m.receivedAt)+'</div></div>';
            html += '<div class="body">'+esc((m.body||'').substring(0,150))+'</div>';
            if (m.reasonForPriority) html += '<div class="reason">⚡ '+esc(m.reasonForPriority)+'</div>';
            // クイック送信ボタン (最初の返信案を巨大ボタンで)
            const mid = esc(m.id).replace(/'/g,"\\\\'");
            if (drafts.length > 0) {
              const d0 = drafts[0];
              const txt0 = esc(d0.text).replace(/'/g,"\\\\'");
              html += '<button class="quick-send" onclick="sendReply(this,\\''+mid+'\\',\\''+txt0+'\\',0)"><span class="qs-icon">⚡</span><div><div class="qs-label">ワンタップ返信</div><div class="qs-text">'+esc(d0.text)+'</div></div><span style="font-size:18px">→</span></button>';
            }
            html += '<div class="replies">';
            visibleDrafts.slice(1).forEach((d, j) => {
              const tc = TONE_COLORS[d.tone] || '#528EFF';
              const tl = TONE_LABELS[d.tone] || d.tone;
              const txt = esc(d.text).replace(/'/g,"\\\\'");
              html += '<div class="reply-row"><div class="tone-icon" style="background:'+tc+'22;color:'+tc+';">'+tl.substring(0,2)+'</div><div class="reply-text">'+esc(d.text)+'</div>';
              html += '<button class="send-btn" onclick="sendReply(this.parentElement,\\''+mid+'\\',\\''+txt+'\\','+(j+1)+')">送信</button>';
              html += '</div>';
            });
            if (moreDrafts > 0) html += '<div class="more-btn" onclick="showAll(this,'+i+')">もっと見る (+'+moreDrafts+')</div>';
            html += '<div style="margin-top:6px;text-align:right;"><button class="skip-btn" onclick="skipMsg(\\''+mid+'\\',this)">スキップ ⏭</button></div>';
            html += '</div></div></div></div>';
          });
          document.getElementById('cards').innerHTML = html;
        }

        function showAll(el, idx) {
          const msgs = filter === 'all' ? allMsgs : allMsgs.filter(m => m.service === filter);
          const m = msgs[idx];
          if (!m) return;
          let html = '';
          (m.drafts||[]).forEach(d => {
            const tc = TONE_COLORS[d.tone]||'#528EFF';
            const tl = TONE_LABELS[d.tone]||d.tone;
            html += '<div class="reply-row" onclick="copyReply(this,\\''+esc(d.text.replace(/'/g,"\\\\'"))+'\\')"><div class="tone-icon" style="background:'+tc+'22;color:'+tc+';">'+tl.substring(0,2)+'</div><div class="reply-text">'+esc(d.text)+'</div><button class="send-btn">コピー</button></div>';
          });
          el.parentElement.innerHTML = html;
        }

        async function sendReply(el, msgId, text, draftIdx) {
          const btn = el.querySelector('.send-btn');
          btn.textContent = '送信中...';
          btn.style.background = '#ff9500';
          try {
            const r = await fetch('/api/send', {
              method:'POST',
              headers:authHeaders(),
              body: JSON.stringify({messageId:msgId, replyText:text, draftIndex:draftIdx})
            });
            const d = await r.json();
            if (d.ok) {
              btn.textContent = '✅ 送信済';
              btn.style.background = '#34c759';
              el.style.opacity = '0.5';
              setTimeout(load, 3000);
            } else {
              btn.textContent = '⚠️ 失敗';
              btn.style.background = '#ff3b30';
            }
          } catch(e) {
            btn.textContent = '⚠️ エラー';
            btn.style.background = '#ff3b30';
          }
        }

        async function skipMsg(msgId, btn) {
          btn.textContent = '...';
          await fetch('/api/skip', {
            method:'POST',
            headers:authHeaders(),
            body: JSON.stringify({messageId:msgId})
          });
          btn.textContent = '✅';
          setTimeout(load, 1000);
        }

        async function skipAllVisible() {
          const msgs = filter === 'all' ? allMsgs : allMsgs.filter(m => m.service === filter);
          if(!confirm(msgs.length+'件を全部スキップしますか？')) return;
          for(const m of msgs) {
            await fetch('/api/skip',{method:'POST',headers:authHeaders(),body:JSON.stringify({messageId:m.id})});
          }
          load();
        }

        function copyReply(el, text) {
          navigator.clipboard.writeText(text).then(() => {
            const btn = el.querySelector('.copy-btn');
            if(btn) { btn.textContent = '✅'; setTimeout(() => btn.textContent = '📋', 1500); }
          });
        }

        function esc(s) { const d=document.createElement('div'); d.textContent=s; return d.innerHTML; }

        function timeAgo(iso) {
          if (!iso) return '';
          const d = new Date(iso);
          const diff = (Date.now() - d.getTime()) / 60000;
          if (diff < 60) return Math.floor(diff)+'分前';
          if (diff < 1440) return Math.floor(diff/60)+'時間前';
          return Math.floor(diff/1440)+'日前';
        }

        load();
        setInterval(load, 15000); // 15秒ごとに自動更新
        </script>
        </body>
        </html>
        """
    }
}
