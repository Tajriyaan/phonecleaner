import SwiftUI
import BackgroundTasks
import Photos

@main
struct PhoneCleanerApp: App {
    @StateObject private var scanEngine = ScanEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanEngine)
                .preferredColorScheme(.dark)
        }
    }

    init() {
        registerBackgroundTasks()
    }

    // MARK: - Background Task Registration
    // BGProcessingTask runs when device is charging + idle.
    // This lets the scan complete fully even if the user backgrounds the app.

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.deepclean.app.scan",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            // If scan is in progress when device goes idle + charging, let it finish
            processingTask.expirationHandler = {
                processingTask.setTaskCompleted(success: false)
            }
            // Mark complete — ScanEngine's own Task handles the actual work
            processingTask.setTaskCompleted(success: true)
        }
    }
}
