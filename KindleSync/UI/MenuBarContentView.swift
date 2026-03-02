import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var syncManager: SyncManager

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
    }
}
