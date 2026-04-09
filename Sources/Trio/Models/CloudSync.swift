import Foundation
import CryptoKit
import Security

/// E2E暗号化クラウド同期
/// - ローカルで AES-GCM 暗号化 (鍵はKeychainに保存)
/// - サーバは暗号化された blob しか見えない
/// - 複数デバイスで同じ鍵を使えばクロス同期可能
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private let keychainKey = "trio_e2e_key"
    private let service = "ai.trio.app"
    private let serverURL = "https://trio-cloud.fly.dev"
    // 鍵はメモリにキャッシュ (Keychainダイアログを最小化)
    private var cachedKey: SymmetricKey?
    private var cachedKeyHex: String?

    /// ローカル暗号化鍵を取得 (無ければ生成)
    private func getOrCreateKey() -> SymmetricKey {
        if let cached = cachedKey { return cached }
        let fileKey = keyFileURL()
        if let data = try? Data(contentsOf: fileKey) {
            let k = SymmetricKey(data: data)
            cachedKey = k
            return k
        }
        // 新規生成してファイルに保存
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        try? data.write(to: fileKey, options: [.atomic])
        // 権限を600に
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileKey.path
        )
        cachedKey = newKey
        return newKey
    }

    private func keyFileURL() -> URL {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Trio", isDirectory: true)
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Trio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".e2e_key")
    }

    /// ユーザー表示用に鍵を16進文字列化
    var currentKeyHex: String {
        if let cached = cachedKeyHex { return cached }
        let key = getOrCreateKey()
        let hex = key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        cachedKeyHex = hex
        return hex
    }

    /// 16進文字列から鍵を復元 (別端末での復号用)
    func setKeyFromHex(_ hex: String) -> Bool {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleaned.count == 64 else { return false }
        var data = Data()
        var index = cleaned.startIndex
        for _ in 0..<32 {
            let next = cleaned.index(index, offsetBy: 2)
            if let byte = UInt8(cleaned[index..<next], radix: 16) {
                data.append(byte)
            } else {
                return false
            }
            index = next
        }
        try? data.write(to: keyFileURL(), options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: keyFileURL().path
        )
        cachedKey = SymmetricKey(data: data)
        cachedKeyHex = nil
        return true
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(_ plaintext: Data) throws -> Data {
        let key = getOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(domain: "CloudSync", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "seal failed"])
        }
        return combined
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        let key = getOrCreateKey()
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Server communication

    /// 現在の state.json + profile.json を暗号化してアップロード
    func uploadSnapshot(deviceId: String, userToken: String) async throws {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("Trio", isDirectory: true)
            ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Trio")

        var payload: [String: Any] = [
            "device_id": deviceId,
            "uploaded_at": ISO8601DateFormatter().string(from: .now)
        ]
        if let stateData = try? Data(contentsOf: dir.appendingPathComponent("state.json")) {
            payload["state"] = stateData.base64EncodedString()
        }
        if let profileData = try? Data(contentsOf: dir.appendingPathComponent("profile.json")) {
            payload["profile"] = profileData.base64EncodedString()
        }
        let plaintext = try JSONSerialization.data(withJSONObject: payload)
        let encrypted = try encrypt(plaintext)

        var req = URLRequest(url: URL(string: "\(serverURL)/v1/sync/upload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = encrypted
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "CloudSync", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "upload failed"])
        }
    }

    /// クラウドから最新スナップショットをダウンロードして復号
    func downloadSnapshot(userToken: String) async throws -> (state: Data?, profile: Data?) {
        var req = URLRequest(url: URL(string: "\(serverURL)/v1/sync/download")!)
        req.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        let plaintext = try decrypt(data)
        guard let obj = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw NSError(domain: "CloudSync", code: 3)
        }
        let stateB64 = obj["state"] as? String
        let profileB64 = obj["profile"] as? String
        return (
            stateB64.flatMap { Data(base64Encoded: $0) },
            profileB64.flatMap { Data(base64Encoded: $0) }
        )
    }

    // MARK: - Keychain (軽量ラッパー)

    private func writeKeychain(_ key: String, data: Data) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    private func readKeychain(_ key: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess {
            return result as? Data
        }
        return nil
    }
}
