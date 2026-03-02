import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var showAuthSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Kindle Sync")
                .font(.headline)

            Divider()

            Text("Status: idle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Sync Now") {
                // Wired in task 6.1
            }
            .buttonStyle(.bordered)

            Divider()

            Button("Log Out") {
                // Wired in task 6.2
            }
            .foregroundStyle(.red)
        }
        .padding()
        .frame(width: 220)
        .onAppear {
            if !syncManager.isAuthenticated {
                showAuthSheet = true
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AmazonAuthSheet { cookies in
                syncManager.handleLoginSuccess(cookies)
            }
        }
    }
}
