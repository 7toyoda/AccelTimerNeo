import Foundation
import StoreKit

/// 買い切り解放（StoreKit 2 非消費型 IAP）を管理する。
/// 計測・履歴の保存・共有はすべて無料・無制限。無料ユーザーが共有する結果カードや動画には
/// 「体験版」の透かしが入り、買い切り解放で透かしが消える（`showsWatermark`）。
@Observable
@MainActor
final class StoreManager {
    /// App Store Connect で登録する非消費型プロダクト ID。
    static let unlockProductID = "com.acceltimer.app.AccelTimer.unlock"

    private(set) var isPurchased = false
    private(set) var product: Product?
    private(set) var purchaseInFlight = false

    /// 表示用の価格文字列（未ロード時は nil）。
    var displayPrice: String? { product?.displayPrice }

    /// 共有時に透かしを入れるか（未購入なら true）。買い切り解放で透かしが消える。
    var showsWatermark: Bool { !isPurchased }

    /// もう1件保存できるか。計測・履歴の保存は無料・無制限になったため常に true。
    /// （課金は「共有物の透かし除去」へ移行。`showsWatermark` 参照）
    /// 保存経路の呼び出し側互換のため関数として残す。
    func canSaveAnother(currentCount: Int) -> Bool { true }

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
