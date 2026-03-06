import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var syncManager: SyncManager

    var body: some View {
        if syncManager.isAuthenticated {
            authenticatedView
        } else {
            AmazonAuthSheet { cookies in
                syncManager.handleLoginSuccess(cookies)
            }
        }
    }

    private var authenticatedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title
            Text("Kindle Sync")
                .font(.headline)

            Divider()

            // Status area
            statusView

            Divider()

            // Sync Now button
            Button {
                Task { await syncManager.sync() }
            } label: {
                Text(syncManager.status == .syncing ? "Syncing…" : "Sync Now")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(syncManager.status == .syncing)

            // Log Out button
            Button("Log Out") {
                syncManager.logOut()
            }
            .foregroundStyle(.red)
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 220)
    }

    // MARK: - Status View

    @ViewBuilder
    private var statusView: some View {
        switch syncManager.status {
        case .idle:
            Text("Ready to sync")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Syncing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success(let date):
            Text("Last synced: \(relativeTime(date))")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .needsAuth:
            Text("Sign in to Amazon")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
