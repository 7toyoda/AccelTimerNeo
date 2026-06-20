import Foundation
import StoreKit

/// 買い切り解放（StoreKit 2 非消費型 IAP）を管理する。
/// 計測自体は常に無料・無制限。無料ユーザーは履歴を `freeHistoryLimit` 件まで保存でき、
/// それを超える保存はブロックしてペイウォールを表示する（ハイブリッド課金モデル）。
@Observable
@MainActor
final class StoreManager {
    /// 無料で保存できる履歴件数。これを超えて保存しようとすると買い切りが必要。
    static let freeHistoryLimit = 5
    /// App Store Connect で登録する非消費型プロダクト ID。
    static let unlockProductID = "com.acceltimer.app.AccelTimer.unlock"

    private(set) var isPurchased = false
    private(set) var product: Product?
    private(set) var purchaseInFlight = false

    /// 表示用の価格文字列（未ロード時は nil）。
    var displayPrice: String? { product?.displayPrice }

    /// 共有時に透かしを入れるか（未購入なら true）。買い切り解放で透かしが消える。
    var showsWatermark: Bool { !isPurchased }

    /// 現在の保存件数で、もう1件保存できるか（購入済みなら常に true）。
    func canSaveAnother(currentCount: Int) -> Bool {
        isPurchased || currentCount < Self.freeHistoryLimit
    }
    /// 無料で残り保存できる件数。
    func freeSlotsRemaining(currentCount: Int) -> Int {
        max(0, Self.freeHistoryLimit - currentCount)
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
