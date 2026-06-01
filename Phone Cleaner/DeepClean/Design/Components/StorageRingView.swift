import SwiftUI

// MARK: - Storage Ring
// Animated arc showing storage used vs. available, with savings projection.

struct StorageRingView: View {
    let usedGB: Double
    let totalGB: Double
    let savingsGB: Double
    let animated: Bool

    @State private var progress: Double = 0
    @State private var savingsProgress: Double = 0

    private var usedFraction: Double { min(1, usedGB / totalGB) }
    private var savingsFraction: Double { min(usedFraction, savingsGB / totalGB) }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Theme.Colors.separator, lineWidth: 20)
                .frame(width: 200, height: 200)

            // Used storage arc
            Circle()
                .trim(from: 0, to: animated ? progress : usedFraction)
                .stroke(
                    AngularGradient(
                        colors: [Theme.Colors.accent, Theme.Colors.accentSecondary],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 20, lineCap: .round)
                )
                .frame(width: 200, height: 200)
                .rotationEffect(.degrees(-90))

            // Savings overlay arc
            Circle()
                .trim(from: usedFraction - (animated ? savingsProgress : savingsFraction),
                      to:   animated ? progress : usedFraction)
                .stroke(Theme.Colors.safe.opacity(0.7),
                        style: StrokeStyle(lineWidth: 20, lineCap: .round))
                .frame(width: 200, height: 200)
                .rotationEffect(.degrees(-90))

            // Centre text
            VStack(spacing: 2) {
                Text(String(format: "%.1f GB", usedGB))
                    .font(Theme.Typography.title)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("of \(String(format: "%.0f", totalGB)) GB used")
                    .font(Theme.Typography.caption)
                    .foregroundColor(Theme.Colors.textSecondary)

                if savingsGB > 0.05 {
                    Text("Save \(String(format: "%.1f", savingsGB)) GB")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.safe)
                        .padding(.top, 4)
                }
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeOut(duration: 1.2)) { progress = usedFraction }
            withAnimation(.easeOut(duration: 1.2).delay(0.3)) { savingsProgress = savingsFraction }
        }
    }
}

// MARK: - Storage Category Bar

struct StorageCategoryBar: View {
    let label: String
    let usedGB: Double
    let color: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textSecondary)
            Spacer()
            Text(String(format: "%.1f GB", usedGB))
                .font(Theme.Typography.caption)
                .foregroundColor(Theme.Colors.textPrimary)
        }
    }
}
