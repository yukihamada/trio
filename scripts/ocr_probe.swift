#!/usr/bin/env swift
// LINE.appのウィンドウをCGWindowListでキャプチャしVision OCRで本文抽出するPoC
import Cocoa
import Vision
import CoreGraphics

guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "jp.naver.line.mac" })?.processIdentifier else {
    print("❌ LINE not running"); exit(1)
}
print("✅ LINE pid=\(pid)")

// CGWindowListでLINEウィンドウのIDを取得
let infos = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
let lineWindows = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
print("LINE windows: \(lineWindows.count)")
for w in lineWindows {
    let name = w[kCGWindowName as String] as? String ?? "(no name)"
    let bounds = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    let wid = w[kCGWindowNumber as String] as? CGWindowID ?? 0
    print("  id=\(wid) name=\"\(name)\" bounds=\(bounds)")
}

guard let target = lineWindows.first(where: { ($0[kCGWindowName as String] as? String)?.isEmpty == false }) ?? lineWindows.first,
      let wid = target[kCGWindowNumber as String] as? CGWindowID else {
    print("❌ no target window"); exit(1)
}

// CGWindowListCreateImage は macOS 14でdeprecated だがまだ動く
guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .nominalResolution]) else {
    print("❌ capture failed (Screen Recording権限が必要)"); exit(1)
}
print("✅ captured: \(cgImage.width)x\(cgImage.height)")

// 保存
let url = URL(fileURLWithPath: "/tmp/line_capture.png")
if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
    CGImageDestinationAddImage(dest, cgImage, nil)
    CGImageDestinationFinalize(dest)
    print("✅ saved /tmp/line_capture.png")
}

// Vision OCR
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.recognitionLanguages = ["ja", "en"]
req.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
do {
    try handler.perform([req])
    let results = req.results ?? []
    print("\n=== OCR結果: \(results.count) 行 ===")
    for (i, obs) in results.enumerated() {
        guard let cand = obs.topCandidates(1).first else { continue }
        let bb = obs.boundingBox
        print("[\(i)] (\(String(format: "%.2f", bb.minY))) \(cand.string)")
        if i > 80 { print("..."); break }
    }
} catch {
    print("❌ OCR error: \(error)")
}
