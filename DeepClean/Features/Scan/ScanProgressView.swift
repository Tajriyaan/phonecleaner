import SwiftUI

// MARK: - Scan Progress View
// Kept intentionally simple for maximum iOS compatibility.

struct ScanProgressView: View {
    @EnvironmentObject var scanEngine: ScanEngine
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            Theme.Colors.background.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Spacer()

                // Icon
                Image(systemName: scanPhaseIcon)
                    .font(.system(size: 64))
                    .foregroundColor(Theme.Colors.accent)
                    .padding(.bottom, Theme.Spacing.sm)

                // Phase label
                Text(scanEngine.scanState.phase.rawValue)
                    .font(Theme.Typography.title)
                    .foregroundColor(Theme.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                // Count
                if scanEngine.scanState.totalCount > 0 {
                    Text("\(scanEngine.scanState.processedCount) of \(scanEngine.scanState.totalCount)")
                        .font(Theme.Typography.body)
                        .foregroundColor(Theme.Colors.textSecondary)
                }

                // Progress bar
                VStack(spacing: Theme.Spacing.sm) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.Colors.separator)
                                .frame(height: 6)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.Colors.accent)
                                .frame(
                                    width: geo.size.width * scanEngine.scanState.progress,
                                    height: 6
                                )
                        }
                    }
                    .frame(height: 6)

                    Text("\(scanEngine.scanState.progressPercent)%")
                        .font(Theme.Typography.caption)
                        .foregroundColor(Theme.Colors.textTertiary)
                }
                .padding(.horizontal, Theme.Spacing.xl)

                // Step list
                stepList

                Spacer()

                // Action button
                if scanEngine.scanState.phase == .complete {
                    Button {
                        dismiss()
                    } label: {
                        Text("View Results")
                            .font(Theme.Typography.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(Theme.Spacing.md)
                            .background(Theme.Colors.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                } else if scanEngine.scanState.phase == .failed {
                    VStack(spacing: Theme.Spacing.sm) {
                        Text(scanEngine.scanState.error?.localizedDescription ?? "Something went wrong.")
                            .font(Theme.Typography.caption)
                            .foregroundColor(Theme.Colors.danger)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Theme.Spacing.lg)
                        Button("Dismiss") {
                            scanEngine.cancelScan()
                            dismiss()
                        }
                        .foregroundColor(Theme.Colors.textTertiary)
                    }
                } else {
                    Button("Cancel") {
                        scanEngine.cancelScan()
                        dismiss()
                    }
                    .font(Theme.Typography.body)
                    .foregroundColor(Theme.Colors.textTertiary)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .onAppear {
            if !scanEngine.isScanning {
                scanEngine.startScan()
            }
        }
        .onChange(of: scanEngine.result) { _, newResult in
            if newResult != nil && scanEngine.isScanning { dismiss() }
        }
    }

    // MARK: - Step List

    private var stepList: some View {
        let steps: [(String, ScanPhase)] = [
            ("Exact Duplicates",   .hashingAssets),
            ("AI Visual Analysis", .visionAnalysis),
            ("Quality Scoring",    .qualityScoring),
            ("Video Analysis",     .videoAnalysis),
            ("Grouping",           .clustering),
            ("Junk Detection",     .junkDetection),
            ("iCloud Check",       .icloudCheck),
        ]

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(steps, id: \.0) { step in
                stepRow(label: step.0, phase: step.1)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func stepRow(label: String, phase: ScanPhase) -> some View {
        let allCases = ScanPhase.allCases
        let currentIdx = allCases.firstIndex(of: scanEngine.scanState.phase) ?? 0
        let phaseIdx   = allCases.firstIndex(of: phase) ?? 0
        let isDone     = currentIdx > phaseIdx
        let isActive   = scanEngine.scanState.phase == phase

        return HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: isDone ? "checkmark.circle.fill" : isActive ? "circle.fill" : "circle")
                .foregroundColor(isDone ? Theme.Colors.safe : isActive ? Theme.Colors.accent : Theme.Colors.textTertiary)
                .font(.system(size: 14))

            Text(label)
                .font(Theme.Typography.body)
                .foregroundColor(isDone ? Theme.Colors.textSecondary : isActive ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
        }
    }

    private var scanPhaseIcon: String {
        switch scanEngine.scanState.phase {
        case .hashingAssets:  return "number.circle.fill"
        case .visionAnalysis: return "eye.circle.fill"
        case .qualityScoring: return "star.circle.fill"
        case .videoAnalysis:  return "video.circle.fill"
        case .clustering:     return "circle.grid.2x2.fill"
        case .junkDetection:  return "trash.circle.fill"
        case .complete:       return "checkmark.circle.fill"
        case .failed:         return "xmark.circle.fill"
        default:              return "sparkle"
        }
    }
}
