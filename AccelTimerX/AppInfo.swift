import Foundation

/// アプリのバージョン情報（画面表示・ログ記録の両方で使う）。
/// バージョンは pbxproj の `MARKETING_VERSION`（CFBundleShortVersionString）で一元管理する。
/// ビルド番号(CFBundleVersion)は表示せず、管理する数字を1つにする。
enum AppInfo {
    static var isAccelTimerX: Bool {
        Bundle.main.bundleIdentifier == "com.acceltimer.app.AccelTimerX"
    }

    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "AccelTimer"
    }

    /// 例: "0.1.1"（マーケティングバージョン）
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
