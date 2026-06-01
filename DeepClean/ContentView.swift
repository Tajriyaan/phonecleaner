import SwiftUI

struct ContentView: View {
    @EnvironmentObject var scanEngine: ScanEngine

    var body: some View {
        TabView {
            DashboardView()
                .environmentObject(scanEngine)
                .tabItem { Label("Clean", systemImage: "sparkles") }

            CategoriesView()
                .environmentObject(scanEngine)
                .tabItem { Label("Categories", systemImage: "square.grid.2x2.fill") }

            NavigationStack {
                WhatsAppView()
                    .environmentObject(scanEngine)
            }
            .tabItem { Label("WhatsApp", systemImage: "bubble.left.and.bubble.right.fill") }
        }
        .tint(Theme.Colors.accent)
    }
}
