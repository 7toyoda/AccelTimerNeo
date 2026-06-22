import SwiftUI

/// GPS許可ダイアログの前に表示する事前アナウンス（プレパーミション）画面。
/// 「なぜ位置情報が必要か」を先に説明してから、システムの許可ダイアログを出す（許可率向上・親切な導線）。
/// 「続ける」を押すと onContinue が呼ばれ、呼び出し側が arm()＝許可要求を発火する。
struct LocationPrimerView: View {
    var onContinue: () -> Void
    private var headlineLabel: String { SpeedUnit.defaultForLocale.headlineLabel }

    var body: some View {
        ZStack {
            // 計測世界観に合わせたディープレッド→ブラック
            LinearGradient(colors: [.black, Color(red: 0.12, green: 0.02, blue: 0.04), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 14) {
                            Image(systemName: "location.fill.viewfinder")
                                .font(.system(size: 56))
                                .foregroundStyle(.blue)
                            Text("位置情報（GPS）を使います")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 12)

                        VStack(alignment: .leading, spacing: 16) {
                            row("speedometer", "GPSのドップラー速度で\(headlineLabel)のタイムを高精度に計測します。")
                            row("location.slash", "位置情報を許可しないと計測できません。")
                            row("lock.shield", "計測データと位置情報は端末内にのみ保存され、外部に送信しません。")
                            row("bolt.car", "次の画面で「Appの使用中は許可」を選んでください。")
                        }
                        .padding(.horizontal, 26)
                    }
                    .padding(.bottom, 24)
                }

                VStack(spacing: 8) {
                    Button(action: onContinue) {
                        Text("続ける")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    Text("次の画面でiOSの許可ダイアログが表示されます。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
    }

    private func row(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.blue.opacity(0.95))
                .frame(width: 28)
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    LocationPrimerView {}
}
