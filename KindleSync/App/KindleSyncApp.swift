import SwiftUI
import ServiceManagement

@main
struct KindleSyncApp: App {
    @StateObject private var syncManager = SyncManager()

    init() {
        try? SMAppService.mainApp.register()
    }

    var body: some Scene {
        MenuBarExtra("Kindle Sync", systemImage: "book.closed") {
            MenuBarContentView()
                .environmentObject(syncManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Kindle Sync Settings")
                .padding()
        }
    }
}
