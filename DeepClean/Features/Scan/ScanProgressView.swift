import SwiftUI

struct ScanProgressView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Spacer()

                // Animated icon
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .stroke(Theme.Colors.accent.opacity(0.2 - Double(i) * 0.06), lineWidth: 1)
                            .frame(width: CGFloat(120 + i * 40))
                            .scaleEffect(pulseScale(index: i))
                            .animation(
                                .easeInOut(duration: 1.5).repeatForever().delay(Double(i) * 0.3),
                                value: scanEngine.scanState.isScanning
                            )
                    }

                    Image(systemName: scanPhaseIcon)
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.Gradients.accent)
                        .rotationEffect(.degrees(scanEngine.scanState.isScanning ? 360 : 0))
                        .animation(
                            .linear(duration: 4).repeatForever(autoreverses: false),
                            value: scanEngine.scanState.isScanning
                        )
                }
                .frame(height: 180)

                // Phase label
                VStack(spacing: Theme.Spacing.sm) {
                    Text(scanEngine.scanState.phase.rawValue)
                        .font(Theme.Typography.title)
                        .foregroundColor(Theme.Colors.textPrimary)
                        .contentTransition(.numericText())
                        .animation(.easeInOut, value: scanEngine.scanState.phase)

                    if scanEngine.scanState.totalCount > 0 {
                        Text("\(scanEngine.scanState.processedCount) / \(scanEngine.scanState.totalCount)")
                            .font(Theme.Typography.body)
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                }

                // Progress bar
                VStack(spacing: Theme.Spacing.sm) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                                .fill(Theme.Colors.separator)
                                .frame(height: 6)

                            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                                .fill(Theme.Gradients.accent)
                                .frame(width: geo.size.width * scanEngine.scanState.progress, height: 6)
                                .animation(.easeInOut(duration: 0.3), value: scanEngine.scanState.progress)
                        }
                    }
                    .frame(height: 6)

                    Text("\(scanEngine.scanState.progressPercent)%")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textTertiary)
                }
                .padding(.horizontal, Theme.Spacing.xl)

                // Phase checklist
                phaseChecklist

                Spacer()

                // Complete / cancel button
                if scanEngine.scanState.phase == .complete {
                    Button {
                        dismiss()
                    } label: {
                        Text("View Results")
                            .font(Theme.Typography.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(Theme.Spacing.md)
                            .background(Theme.Gradients.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                } else {
                    Button {
                        scanEngine.cancelScan()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(Theme.Typography.body)
                            .foregroundColor(Theme.Colors.textTertiary)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    // MARK: - Phase Checklist

    private var phaseChecklist: some View {
        let phases: [(String, ScanPhase)] = [
            ("Exact Duplicates",   .hashingAssets),
            ("AI Visual Analysis", .visionAnalysis),
            ("Quality Scoring",    .qualityScoring),
            ("Video Analysis",     .videoAnalysis),
            ("Clustering Groups",  .clustering),
            ("Junk Detection",     .junkDetection),
            ("iCloud Check",       .icloudCheck),
        ]
        let currentIdx = ScanPhase.allCases.firstIndex(of: scanEngine.scanState.phase) ?? 0

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(phases, id: \.0) { label, phase in
                let phaseIdx = ScanPhase.allCases.firstIndex(of: phase) ?? 0
                let isDone = currentIdx > phaseIdx
                let isActive = currentIdx == phaseIdx

                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : isActive ? "circle.fill" : "circle")
                        .foregroundColor(isDone ? Theme.Colors.safe : isActive ? Theme.Colors.accent : Theme.Colors.textTertiary)
                        .font(.system(size: 14))

                    Text(label)
                        .font(Theme.Typography.body)
                        .foregroundColor(isDone ? Theme.Colors.textSecondary : isActive ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var scanPhaseIcon: String {
        switch scanEngine.scanState.phase {
        case .hashingAssets:  return "number.circle"
        case .visionAnalysis: return "eye.circle"
        case .qualityScoring: return "star.circle"
        case .videoAnalysis:  return "video.circle"
        case .clustering:     return "circle.grid.2x2"
        case .junkDetection:  return "trash.circle"
        case .complete:       return "checkmark.circle"
        default:              return "sparkle"
        }
    }

    private func pulseScale(index: Int) -> CGFloat {
        scanEngine.scanState.isScanning ? 1.15 : 1.0
    }
}
