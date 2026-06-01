import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scanEngine: ScanEngine

    var body: some View {
        DashboardView()
            .environmentObject(scanEngine)
    }
}
