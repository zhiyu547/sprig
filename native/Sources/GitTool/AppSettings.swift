// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation
import Security
import CryptoKit
import GitCore

@MainActor final class AppSettings: ObservableObject {
    @Published var ai: AIConfiguration
    @Published var checkWhitespace: Bool
    @Published var checkTODO: Bool
    @Published var signOff: Bool
    @Published var authorOverride: String
    init() {
        ai = UserDefaults.standard.data(forKey: "Sprig.aiConfiguration").flatMap { try? JSONDecoder().decode(AIConfiguration.self, from: $0) } ?? AIConfiguration()
        checkWhitespace = UserDefaults.standard.object(forKey: "Sprig.checkWhitespace") as? Bool ?? true
        checkTODO = UserDefaults.standard.object(forKey: "Sprig.checkTODO") as? Bool ?? true
        signOff = UserDefaults.standard.bool(forKey: "Sprig.signOff")
        authorOverride = UserDefaults.standard.string(forKey: "Sprig.authorOverride") ?? ""
    }
    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(ai), forKey: "Sprig.aiConfiguration")
        UserDefaults.standard.set(checkWhitespace, forKey: "Sprig.checkWhitespace")
        UserDefaults.standard.set(checkTODO, forKey: "Sprig.checkTODO")
        UserDefaults.standard.set(signOff, forKey: "Sprig.signOff")
        UserDefaults.standard.set(authorOverride, forKey: "Sprig.authorOverride")
    }
    var commitOptions: CommitOptions { CommitOptions(signOff: signOff, author: authorOverride, checkWhitespace: checkWhitespace) }
}

enum KeychainStore {
    private static func query(_ endpoint: String) -> [String: Any] {
        let account = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cn.gittool.native.ai", kSecAttrAccount as String: account]
    }
    static func read(endpoint: String) async throws -> String {
        try await withDeadline(seconds: 20, message: "读取 API Key 超时。如有 macOS 钥匙串授权提示，请完成授权后重试；也可在设置中重新保存密钥。") {
            try readBlocking(endpoint: endpoint)
        }
    }
    private static func readBlocking(endpoint: String) throws -> String {
        var query = query(endpoint); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw GitError.message("无法读取钥匙串中的 API Key（\(status)）。") }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, endpoint: String) async throws {
        // Keychain can wait for securityd or an authorization dialog; never block AppKit.
        try await Task.detached { try saveBlocking(key, endpoint: endpoint) }.value
    }
    private static func saveBlocking(_ key: String, endpoint: String) throws {
        let query = query(endpoint)
        if key.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw GitError.message("无法移除 API Key（\(status)）。") }; return }
        let update = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(update) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitError.message("API Key 保存失败（\(status)），设置未完成。") }
    }
}
