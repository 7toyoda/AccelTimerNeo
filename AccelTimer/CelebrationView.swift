import SwiftUI

/// 新記録（自己ベスト更新）を出した「ピーク」の瞬間に表示する祝福シート。
/// トロフィーカードを見せて共有を促し、無料ユーザーには透かし除去（買い切り）を訴求する。
/// 計測はブロックしない（あくまで祝福＋任意の課金導線）。
struct CelebrationView: View {
    let record: MeasurementRecord
    let store: StoreManager
    /// 透かしを消す（ペイウォールを開く）。
    var onUnlock: () -> Void
    /// 閉じる。
    var onClose: () -> Void

    @State private var shareURL: URL?
    @State private var glow = false
    @AppStorage("speedUnit") private var speedUnitRaw: String = SpeedUnit.defaultForLocale.rawValue
    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.14, green: 0.02, blue: 0.05), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    closeButton
                    VStack(spacing: 4) {
                        Text("🎉 新記録！")
                            .font(.system(size: 30, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text("\(unit.headlineLabel) を更新しました")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // トロフィーカードのプレビュー（無料は透かし付き）
                    ResultCardView(record: record, showsWatermark: store.showsWatermark, unit: unit)
                        .shadow(color: .yellow.opacity(glow ? 0.5 : 0.2), radius: glow ? 24 : 10)
                    shareButton
                    if store.showsWatermark {
                        unlockButton
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            shareURL = ResultCardRenderer.renderURL(record: record,
                                                    showsWatermark: store.showsWatermark,
                                                    unit: unit)
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
        }
    }

    private var closeButton: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(.white.opacity(0.08), in: Circle())
            }
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = shareURL {
            ShareLink(item: url,
                      preview: SharePreview("計測結果カード", image: Image(systemName: "rosette"))) {
                Label("結果カードを共有", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(colors: [.yellow, Color(red: 1, green: 0.7, blue: 0)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var unlockButton: some View {
        VStack(spacing: 6) {
            Button(action: onUnlock) {
                Label("透かしを消す（解放）", systemImage: "lock.open.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2), lineWidth: 1))
            }
            Text("買い切りで「体験版」の透かしが消え、クリーンな結果カードを共有できます")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
