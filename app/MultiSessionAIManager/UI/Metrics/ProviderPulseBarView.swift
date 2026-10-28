import SwiftUI

struct ProviderPulseBarView: View {
    var pulse: ProviderPulseModel
    var onSelectProvider: (ProviderQuota) -> Void

    init(pulse: ProviderPulseModel, onSelectProvider: @escaping (ProviderQuota) -> Void) {
        self.pulse = pulse
        self.onSelectProvider = onSelectProvider
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(pulse.activeProviders) { provider in
                Button {
                    onSelectProvider(provider)
                } label: {
                    HStack(spacing: 4) {
                        ProviderIconView(providerName: provider.name, size: 14)
                        
                        Text("\(Int(provider.usedPercent.rounded()))%")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                            .foregroundStyle(provider.isRateLimited ? HerdrTheme.red : HerdrTheme.text)

                        if provider.isRateLimited {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(HerdrTheme.red)
                        } else if let credits = provider.resetCredits, credits.availableCount > 0 {
                            Circle()
                                .fill(HerdrTheme.green)
                                .frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(provider.isRateLimited ? HerdrTheme.red.opacity(0.15) : HerdrTheme.selection)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(provider.isRateLimited ? HerdrTheme.red.opacity(0.4) : Color.clear, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(provider.displayName): \(Int(provider.usedPercent)) percent used")
            }
        }
    }
}
