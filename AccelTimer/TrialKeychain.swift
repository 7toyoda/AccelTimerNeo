import Foundation
import Security

/// 無料計測の使用回数を Keychain に保存する。
/// Keychain はアプリを削除しても残るため、再インストールによる無料枠リセットを防げる
/// （UserDefaults はアプリ削除で消えるのでトライアル管理には使えない）。
enum TrialKeychain {
    private static let service = "com.acceltimer.app.AccelTimer.trial"
    private static let account = "free_measurement_count"

    /// 無料計測の累積使用回数。読み取り失敗時は 0。
    static var measurementCount: Int {
        get {
            guard let data = read(),
                  let str = String(data: data, encoding: .utf8),
                  let n = Int(str) else { return 0 }
            return n
        }
        set { write(Data(String(newValue).utf8)) }
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data) {
        let query = baseQuery()
        // アクセシビリティ：初回アンロック以降は常に読めて、デバイス移行・再インストール後も残る
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
