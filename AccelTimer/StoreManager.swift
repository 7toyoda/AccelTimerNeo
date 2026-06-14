import Foundation
import StoreKit

/// 無料計測枠（Keychain 永続）と買い切り解放（StoreKit 2 非消費型 IAP）を管理する。
/// `isUnlocked` が false の間は新規計測をブロックし、ペイウォールを表示する。
@Observable
@MainActor
final class StoreManager {
    /// 無料で計測できる回数（完走＝100km/h到達のみカウント）。これを超えると買い切りが必要。
    /// ※ 検証中は 1000。リリース時は 20 等に戻すこと。
    static let freeMeasurementLimit = 1000
    /// App Store Connect で登録する非消費型プロダクト ID。
    static let unlockProductID = "com.acceltimer.app.AccelTimer.unlock"

    private(set) var isPurchased = false
    private(set) var freeUsed: Int
    private(set) var product: Product?
    private(set) var purchaseInFlight = false

    /// 計測可能か（購入済み、または無料枠が残っている）。
    var isUnlocked: Bool { isPurchased || freeUsed < Self.freeMeasurementLimit }
    /// 残りの無料計測回数。
    var freeRemaining: Int { max(0, Self.freeMeasurementLimit - freeUsed) }
    /// 表示用の価格文字列（未ロード時は nil）。
    var displayPrice: String? { product?.displayPrice }

    init() {
        freeUsed = TrialKeychain.measurementCount
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

    /// 計測が保存されたら呼ぶ。未購入時のみ無料カウントを Keychain に加算する。
    func registerMeasurement() {
        guard !isPurchased else { return }
        TrialKeychain.measurementCount += 1
        freeUsed = TrialKeychain.measurementCount
    }
}
