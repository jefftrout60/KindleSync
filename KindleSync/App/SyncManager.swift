import SwiftUI
import Foundation

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case failed(String)
    case needsAuth
}

@MainActor
final class SyncManager: ObservableObject {
    @Published var status: SyncStatus = .idle
    @Published var isAuthenticated: Bool = false

    private let lastSyncKey = "lastSyncDate"
    private let syncIntervalSeconds: TimeInterval = 7 * 24 * 3600 // 7 days

    init() {
        // Check if credentials exist in Keychain on startup
        // Full check wired in task 2.3; for now just set false
        isAuthenticated = false
    }

    func sync() async {
        guard status != .syncing else { return }
        status = .syncing
        // Full implementation wired in task 5.1
        // Stub: simulate completion
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        status = .idle
    }

    func checkAndSchedule() {
        guard isAuthenticated else { return }
        guard status != .syncing else { return }

        if shouldSync() {
            Task { await sync() }
        }
    }

    private func shouldSync() -> Bool {
        guard let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date else {
            return true // never synced
        }
        return Date().timeIntervalSince(lastSync) >= syncIntervalSeconds
    }

    func markSyncComplete() {
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
    }

    func clearSyncHistory() {
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
    }

    var lastSyncDate: Date? {
        UserDefaults.standard.object(forKey: lastSyncKey) as? Date
    }
}
