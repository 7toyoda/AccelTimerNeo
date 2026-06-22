import SwiftUI

/// 起動オンボーディングの先頭に表示するウェルカム画面。
/// 第一印象を法的文面ではなくブランド/価値にして警戒感を和らげる狙い。
/// 「はじめる」で onStart → 次（安全・同意）へ進む。
struct WelcomeView: View {
    var onStart: () -> Void

    @State private var glow = false
    @State private var edgeAngle: Double = 0
    private var headlineLabel: String { SpeedUnit.defaultForLocale.headlineLabel }

    private static let features: [(String, LocalizedStringKey)] = [
        ("scope",             "GPS×加速度センサーで高精度計測"),
        ("video.fill",        "走行動画にタイムをオーバーレイ録画"),
        ("chart.xyaxis.line", "スプリット・速度・加速度を詳細分析")
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [.black, Color(red: 0.13, green: 0.02, blue: 0.05), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            SpeedLinesView().opacity(0.5)
            edgeGlow

            VStack(spacing: 0) {
                Spacer(minLength: 24)
                // ヒーロー：発光するスピードメーター
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.18))
                        .frame(width: 190, height: 190)
                        .blur(radius: 30)
                        .scaleEffect(glow ? 1.12 : 0.9)
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 96))
                        .foregroundStyle(.white)
                        .shadow(color: .cyan.opacity(0.8), radius: glow ? 26 : 12)
                }

                Text(AppInfo.displayName)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 18)
                Text("\(headlineLabel) を、プロ級の精度で。")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.features, id: \.0) { icon, label in
                        HStack(spacing: 14) {
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.cyan)
                                .frame(width: 26)
                            Text(label)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)

                Spacer(minLength: 24)

                Button(action: onStart) {
                    Text("はじめる")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(
                            LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.black)
                        .shadow(color: .cyan.opacity(glow ? 0.6 : 0.3), radius: glow ? 18 : 8)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(true)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { edgeAngle = 360 }
        }
    }

    private var edgeGlow: some View {
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1.0, brightness: 1.0) }
        return Rectangle()
            .stroke(AngularGradient(gradient: Gradient(colors: hues),
                                    center: .center, angle: .degrees(edgeAngle)),
                    lineWidth: 34)
            .blur(radius: 24)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(glow ? 0.55 : 0.3)
    }
}

#Preview {
    WelcomeView {}
}
