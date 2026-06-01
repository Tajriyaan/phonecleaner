import Foundation
import Observation

// MARK: - Scan Phase

enum ScanPhase: String, CaseIterable {
    case idle           = "Ready"
    case requestingAccess = "Requesting Access"
    case loadingLibrary = "Loading Library"
    case hashingAssets  = "Finding Exact Duplicates"
    case visionAnalysis = "AI Visual Analysis"
    case qualityScoring = "Scoring Photo Quality"
    case videoAnalysis  = "Analysing Videos"
    case clustering     = "Grouping Similar Media"
    case icloudCheck    = "Checking iCloud"
    case whatsappCheck  = "Scanning WhatsApp Media"
    case junkDetection  = "Detecting Junk Shots"
    case finalising     = "Finalising Results"
    case complete       = "Scan Complete"
    case failed         = "Scan Failed"
}

// MARK: - Scan State

@Observable
final class ScanState {
    var phase: ScanPhase = .idle
    var progress: Double = 0           // 0-1
    var processedCount: Int = 0
    var totalCount: Int = 0
    var currentAssetDescription: String = ""
    var error: Error?

    var isScanning: Bool {
        phase != .idle && phase != .complete && phase != .failed
    }

    var progressPercent: Int { Int(progress * 100) }

    var phaseDescription: String {
        guard totalCount > 0 else { return phase.rawValue }
        return "\(phase.rawValue) — \(processedCount)/\(totalCount)"
    }

    func update(phase: ScanPhase, processed: Int = 0, total: Int = 0, description: String = "") {
        self.phase = phase
        self.processedCount = processed
        self.totalCount = total
        self.currentAssetDescription = description
        if total > 0 { self.progress = Double(processed) / Double(total) }
    }
}
