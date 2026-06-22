import SwiftUI

/// 初回起動時に表示する免責事項の同意画面。
/// 「同意する」を押すまで本文を読ませ、同意を AppStorage に記録する。
/// 設定からも再表示できる（isFirstLaunch=false で開いた場合は同意ボタンを「閉じる」に）。
struct DisclaimerView: View {
    /// 初回起動の同意フローか（true=同意ボタン表示／false=閲覧のみで閉じる）
    var isFirstLaunch: Bool
    var onAgree: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 52))
                                .foregroundStyle(.cyan)
                            Text("安全運転と免責事項")
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        Group {
                            bullet("本アプリは加速性能を計測するための補助ツールです。公道での速度超過や危険運転を推奨するものではありません。")
                            bullet("計測は、安全が確保され法令上も許される場所でのみ行ってください。")
                            bullet("運転者は道路交通法をはじめとする一切の法令を遵守し、常に周囲の安全を最優先してください。")
                            bullet("運転者は端末を操作せず、計測の開始・停止や画面の確認は同乗者が行うか、停車中に行ってください。")
                            bullet("本アプリの利用に起因または関連して生じた事故・違反・損害・トラブルについて、開発者は一切の責任を負いません。利用者ご自身の責任においてご利用ください。")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }

                VStack(spacing: 10) {
                    Button(action: onAgree) {
                        Text(isFirstLaunch ? "同意して始める" : "閉じる")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(
                                LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.black)
                    }
                    if isFirstLaunch {
                        Text("「同意して始める」を押すと、上記に同意したものとみなします。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isFirstLaunch)   // 初回は同意必須（スワイプで閉じさせない）
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.cyan.opacity(0.9))
                .padding(.top, 2)
            Text(text)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    DisclaimerView(isFirstLaunch: true) {}
}
