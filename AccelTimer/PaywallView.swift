import SwiftUI

/// 無料枠を使い切った時に表示する購入画面。買い切り（非消費型）で全機能を永久解放。
/// アプリの世界観に合わせたレーシング調・カラフルなエッジ演出で訴求する。
struct PaywallView: View {
    let store: StoreManager
    var onClose: () -> Void

    @State private var restoring = false
    @State private var purchaseFailed = false
    @State private var restoreEmpty = false
    @State private var glow = false
    @State private var edgeAngle: Double = 0

    private static let features: [(String, LocalizedStringKey)] = [
        ("infinity",            "計測が無制限"),
        ("video.fill",          "走行動画オーバーレイ録画"),
        ("chart.xyaxis.line",   "履歴・スプリット詳細・速度グラフ")
    ]

    var body: some View {
        ZStack {
            // 背景：黒 → ディープなレーシングレッド → 黒
            LinearGradient(colors: [.black, Color(red: 0.14, green: 0.02, blue: 0.05), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            edgeGlow
            SpeedLinesView()   // 計測中と同じ放射スピードライン

            // 横画面でも購入ボタンに届くようスクロール可能にする
            ScrollView {
                VStack(spacing: 18) {
                    closeButton
                    hero
                    VStack(spacing: 6) {
                        Text("プロ仕様の精度を、すべて解放")
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Text("一度の購入で、ずっと使えます")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    oneTimeBadge
                    featureList
                    purchaseButton
                        .padding(.top, 6)
                    secondaryButtons
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .alert("購入を完了できませんでした", isPresented: $purchaseFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert("復元できる購入が見つかりませんでした", isPresented: $restoreEmpty) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            // 初回ロード失敗(ネットワーク不調等)に備え、商品が未取得なら再試行する
            if store.product == nil { Task { await store.loadProduct() } }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { edgeAngle = 360 }
        }
    }

    // MARK: Parts

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

    private var hero: some View {
        ZStack {
            Circle()
                .fill(Color.yellow.opacity(0.18))
                .frame(width: 150, height: 150)
                .blur(radius: 24)
                .scaleEffect(glow ? 1.12 : 0.9)
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 70))
                .foregroundStyle(.yellow)
                .shadow(color: .yellow.opacity(0.8), radius: glow ? 26 : 12)
        }
    }

    private var oneTimeBadge: some View {
        Label("買い切り・サブスクなし", systemImage: "checkmark.seal.fill")
            .font(.footnote.weight(.bold))
            .foregroundStyle(.green)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.green.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.green.opacity(0.35), lineWidth: 1))
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.features, id: \.0) { icon, label in
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 28)
                    Text(label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var purchaseButton: some View {
        Button {
            Task {
                let ok = await store.purchase()
                if ok { onClose() } else { purchaseFailed = true }
            }
        } label: {
            Group {
                if store.purchaseInFlight {
                    ProgressView().tint(.black)
                } else if let price = store.displayPrice {
                    Text("\(price) で全機能を解放")
                } else {
                    Text("購入して解放")
                }
            }
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                LinearGradient(colors: [.yellow, Color(red: 1, green: 0.7, blue: 0)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(.black)
            .shadow(color: .yellow.opacity(glow ? 0.6 : 0.25), radius: glow ? 20 : 8)
        }
        .disabled(store.purchaseInFlight || store.product == nil)
        .scaleEffect(glow ? 1.015 : 1.0)
    }

    private var secondaryButtons: some View {
        HStack(spacing: 22) {
            Button {
                Task {
                    restoring = true
                    await store.restore()
                    restoring = false
                    if store.isPurchased { onClose() } else { restoreEmpty = true }
                }
            } label: {
                Text(restoring ? "復元中…" : "購入を復元")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(.white.opacity(0.10), in: Capsule())
            }
            .disabled(restoring)

            Button(action: onClose) {
                Text("あとで")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    .background(.white.opacity(0.10), in: Capsule())
            }
        }
    }

    // 計測中(runningEdgeGlow)と同じフル彩度の虹エッジ（外周＝原色／内側＝白み の2層）
    private var edgeGlow: some View {
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1.0, brightness: 1.0) }
        return ZStack {
            Rectangle()
                .stroke(AngularGradient(gradient: Gradient(colors: hues),
                                        center: .center, angle: .degrees(edgeAngle)),
                        lineWidth: 34)
                .blur(radius: 12)
                .blendMode(.plusLighter)
            Rectangle()
                .stroke(Color.white, lineWidth: 22)
                .blur(radius: 26)
                .padding(34)
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(glow ? 1.0 : 0.78)
    }
}
