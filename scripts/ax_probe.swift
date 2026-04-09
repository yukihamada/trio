#!/usr/bin/env swift
import Cocoa
import ApplicationServices

// LINE.appのAX UI階層をdumpするPoC
// 使い方: swift ax_probe.swift

guard AXIsProcessTrusted() else {
    print("❌ Accessibility権限が必要です")
    print("   システム設定 → プライバシーとセキュリティ → アクセシビリティ → Terminal を追加")
    exit(1)
}

let bundleId = "jp.naver.line.mac"
let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleId }
guard let app = apps.first else {
    print("❌ LINE.app is not running")
    exit(1)
}

print("✅ LINE.app pid=\(app.processIdentifier)")

let axApp = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ el: AXUIElement, _ name: String) -> Any? {
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, name as CFString, &v)
    return err == .success ? v : nil
}

func dump(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 6, maxChildren: Int = 12) {
    if depth > maxDepth { return }
    let role = (attr(el, "AXRole") as? String) ?? "?"
    let title = (attr(el, "AXTitle") as? String) ?? ""
    let value = (attr(el, "AXValue") as? String) ?? ""
    let desc = (attr(el, "AXDescription") as? String) ?? ""

    let titlePart = title.isEmpty ? "" : " title=\"\(title.prefix(40))\""
    let valuePart = value.isEmpty ? "" : " value=\"\(value.prefix(60))\""
    let descPart = desc.isEmpty ? "" : " desc=\"\(desc.prefix(40))\""

    let indent = String(repeating: "  ", count: depth)
    print("\(indent)[\(role)]\(titlePart)\(valuePart)\(descPart)")

    if let children = attr(el, "AXChildren") as? [AXUIElement] {
        for (i, c) in children.enumerated() {
            if i >= maxChildren {
                print("\(indent)  ... (+\(children.count - maxChildren) more)")
                break
            }
            dump(c, depth: depth + 1, maxDepth: maxDepth, maxChildren: maxChildren)
        }
    }
}

print("=== LINE.app text extraction ===")
var textCount = 0
var sampleTexts: [String] = []

func walkForText(_ el: AXUIElement, depth: Int = 0) {
    if depth > 30 { return }
    var attrNames: CFArray?
    AXUIElementCopyAttributeNames(el, &attrNames)
    let names = (attrNames as? [String]) ?? []

    for name in names {
        if let v = attr(el, name) as? String, !v.isEmpty, v.count > 1, v.count < 500 {
            // role/identifier系は除外
            if name.contains("Role") || name.contains("Identifier") || name.contains("Subrole") {
                continue
            }
            textCount += 1
            if sampleTexts.count < 30 {
                sampleTexts.append("[\(name)] \(v)")
            }
        }
    }
    if let children = attr(el, "AXChildren") as? [AXUIElement] {
        for c in children { walkForText(c, depth: depth + 1) }
    }
}

if let windows = attr(axApp, "AXWindows") as? [AXUIElement] {
    print("Windows: \(windows.count)")
    for w in windows { walkForText(w) }
}

print("\n総テキスト要素数: \(textCount)")
print("サンプル30件:")
for s in sampleTexts {
    print("  \(s)")
}
