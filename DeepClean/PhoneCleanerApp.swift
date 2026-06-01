import SwiftUI
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
}
