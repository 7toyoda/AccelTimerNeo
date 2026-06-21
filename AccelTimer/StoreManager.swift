import Foundation
import StoreKit

/// 買い切り解放（StoreKit 2 非消費型 IAP）と無料トライアルを管理する。
/// 課金モデル：累計 `freeTrialLimit` 回の完走まで無料。使い切った後も「1日1回」は無料で完走でき、
/// それ以上は買い切り解放（無制限）が必要。カウントは `TrialKeychain`（再インストールでもリセット不可）。
@Observable
@MainActor
final class StoreManager {
    /// App Store Connect で登録する非消費型プロダクト ID。
    static let unlockProductID = "com.acceltimer.app.AccelTimer.unlock"
    /// 無料で完走できる累計回数。これを超えると「1日1回」のみ無料。
    static let freeTrialLimit = 30

    private(set) var isPurchased = false
    private(set) var product: Product?
    private(set) var purchaseInFlight = false
    /// 無料完走の累計回数（Keychain ミラー・UI 反映用に @Observable 化）。
    private(set) var trialCount: Int = TrialKeychain.measurementCount
    /// 最後に無料完走した日（"yyyy-MM-dd"）。
    private(set) var lastFreeDay: String = TrialKeychain.lastFreeDay

    /// 表示用の価格文字列（未ロード時は nil）。
    var displayPrice: String? { product?.displayPrice }

    /// 今日の年月日（ローカル）。"yyyy-MM-dd"。
    private static var todayString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar.current
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 累計枠を使い切ったか。
    var trialExhausted: Bool { trialCount >= Self.freeTrialLimit }
    /// 今日すでに無料完走を使ったか（累計枠超過後の「1日1回」判定用）。
    var freeUsedToday: Bool { lastFreeDay == Self.todayString }
    /// 無料枠の残り回数（累計枠内のみ。0 になったら「1日1回」運用）。
    var freeTrialRemaining: Int { max(0, Self.freeTrialLimit - trialCount) }

    /// 新しい計測を開始してよいか。
    /// 購入済み or 累計枠が残っている or（枠超過でも）今日まだ無料完走していない、なら可。
    var canMeasure: Bool { isPurchased || !trialExhausted || !freeUsedToday }

    /// 完走（headline 到達）した計測を 1 回ぶん記録する。購入済みなら何もしない。
    func registerCompletedMeasurement() {
        guard !isPurchased else { return }
        trialCount += 1
        TrialKeychain.measurementCount = trialCount
        lastFreeDay = Self.todayString
        TrialKeychain.lastFreeDay = lastFreeDay
    }

    init() {
        // App Store 外（他デバイスでの購入・返金など）からのトランザクション更新を監視
        Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let t) = update {
                    await t.finish()
                    await self.refreshEntitlement()
                }
            }
        }
        Task { await loadProduct(); await refreshEntitlement() }
    }

    func loadProduct() async {
        product = try? await Product.products(for: [Self.unlockProductID]).first
    }

    /// 現在の購入権利（entitlement）を確認して isPurchased を更新。
    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Self.unlockProductID,
               t.revocationDate == nil {
                isPurchased = true
                return
            }
        }
        isPurchased = false
    }

    /// 購入を実行。成功で true。
    @discardableResult
    func purchase() async -> Bool {
        guard let product else { return false }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result,
               case .verified(let transaction) = verification {
                await transaction.finish()
                isPurchased = true
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// 購入の復元（機種変更・再インストール時）。
    func restore() async {
        try? await AppStore.sync()
        await refreshEntitlement()
    }
}
