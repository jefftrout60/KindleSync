import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject var syncManager: SyncManager
    @State private var selectedInterval: SyncInterval? = nil
    @State private var previousInterval: SyncInterval? = nil
    @State private var showFirstSyncAlert: Bool = false

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

            Divider()

            // Schedule picker
            Picker("Auto-Sync", selection: $selectedInterval) {
                Text("Off").tag(SyncInterval?.none)
                ForEach(SyncInterval.allCases) { interval in
                    Text(interval.displayName).tag(SyncInterval?.some(interval))
                }
            }
            .pickerStyle(.radioGroup)
            .onAppear {
                selectedInterval = syncManager.scheduleInterval
                previousInterval = syncManager.scheduleInterval
            }
            .onChange(of: selectedInterval) { newValue in
                guard newValue != syncManager.scheduleInterval else { return }
                // Only notify when newly enabling (nil → non-nil) or disabling (non-nil → nil)
                // Switching between intervals is a silent update (REQ-004)
                let notify = previousInterval == nil || newValue == nil
                // Show "First sync now?" if newly enabling with no prior sync history
                if newValue != nil && previousInterval == nil && syncManager.lastSyncDate == nil {
                    showFirstSyncAlert = true
                }
                previousInterval = newValue
                syncManager.setSchedule(newValue, notify: notify)
            }

            // First sync prompt (inline — avoids popover dismissal race with system alerts)
            if showFirstSyncAlert {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run first sync now?")
                        .font(.caption)
                    HStack(spacing: 8) {
                        Button("Sync Now") {
                            showFirstSyncAlert = false
                            Task { await syncManager.sync() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Later") {
                            showFirstSyncAlert = false
                        }
                        .buttonStyle(.plain)
                        .controlSize(.small)
                    }
                }
            }

            // Next scheduled sync display
            if let nextSync = syncManager.nextScheduledSync {
                Text("Next: \(formattedNextSync(nextSync))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Text("Last synced: \(formattedTime(date))")
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

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formattedNextSync(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
