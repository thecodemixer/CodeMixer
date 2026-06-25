import SwiftUI

/// Token + cost-USD pill, hidden by default. Surfaced only when
/// `appearance.showUsageChip == true`.
public struct CostBadgeView: View {
    public let tokens: Int
    public let costUSD: Double?

    public init(tokens: Int, costUSD: Double?) {
        self.tokens = tokens
        self.costUSD = costUSD
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "bolt.fill").foregroundStyle(Theme.signal.warning)
                .accessibilityLabel("Cost")
            Text("\(formattedTokens) tok").font(Theme.typography.caption).monospacedDigit()
            if let costUSD {
                Text(String(format: "$%.4f", costUSD))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, 3)
        .background(Theme.surface.bubble, in: Capsule())
        .accessibilityLabel(label)
    }

    private var formattedTokens: String {
        if tokens > 10_000 { return "\(tokens / 1_000)k" }
        return "\(tokens)"
    }

    private var label: String {
        let cost = costUSD.map { String(format: "%.4f USD", $0) } ?? "unknown cost"
        return "Usage: \(tokens) tokens, \(cost)"
    }
}
