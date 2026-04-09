import SwiftUI
import AppKit
import Foundation

func tlog(_ s: String) {
    let line = "[\(Date())] \(s)\n"
    let path = "/tmp/trio.log"
    if FileManager.default.fileExists(atPath: path) {
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        }
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    }
}

class TrioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        tlog("[delegate] willFinishLaunching")
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        tlog("[delegate] didFinishLaunching")
        // Dock に出して普通のウィンドウアプリとして動作 + メニューバーアイコンも併設
        NSApp.setActivationPolicy(.regular)
        tlog("[delegate] policy set to regular")
        NSApp.activate(ignoringOtherApps: true)
        // ローカル Web サーバ (LAN内スマホ用)
        WebServer.shared.appStore = globalStore
        WebServer.shared.start()
        tlog("[delegate] web server: \(WebServer.shared.lanURL ?? WebServer.shared.localURL)")
        // クラウドリレー (Trio Cloud接続時のみ)
        if let store = globalStore {
            ServerRelay.shared.start(store: store)
            tlog("[delegate] server relay started")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            tlog("[delegate] auto-refresh start")
            await globalStore?.refresh()
            tlog("[delegate] auto-refresh done: \(globalStore?.messages.count ?? -1) msgs")
        }
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    // Dockクリックでウィンドウ再表示
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for w in sender.windows {
                w.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

// グローバル参照 (AppDelegateからアクセス用)
@MainActor var globalStore: AppStore?

@main
struct TrioApp: App {
    @NSApplicationDelegateAdaptor(TrioAppDelegate.self) var delegate
    @StateObject private var store: AppStore

    init() {
        try? "[\(Date())] [TrioApp.init] start\n".data(using: .utf8)?
            .write(to: URL(fileURLWithPath: "/tmp/trio.log"))
        let s = AppStore()
        _store = StateObject(wrappedValue: s)
        Task { @MainActor in globalStore = s }
        tlog("[TrioApp.init] AppStore created")
    }

    var body: some Scene {
        // 1. メインウィンドウ (フルスクリーン可、通常サイズ起動)
        Window("Trio", id: "main") {
            TripleCardView(store: store)
                .frame(minWidth: 460, minHeight: 600)
                .task { await store.refresh() }
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}  // Cmd+N無効化
            CommandGroup(after: .appInfo) {
                Button("更新") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        // 2. メニューバー常駐アイコン (クイックアクセス)
        MenuBarExtra {
            TripleCardView(store: store)
                .frame(width: 440, height: 600)
                .task { await store.refresh() }
        } label: {
            if let path = Bundle.main.path(forResource: "TrioTemplate", ofType: "png"),
               let img = NSImage(contentsOfFile: path) {
                let _ = { img.isTemplate = true }()
                Image(nsImage: img)
            } else {
                Image(systemName: "tray.full")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
