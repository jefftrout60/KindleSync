import SwiftUI

@main
struct KindleSyncApp: App {
    var body: some Scene {
        MenuBarExtra("Kindle Sync", systemImage: "book.closed") {
            Text("Kindle Sync")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
