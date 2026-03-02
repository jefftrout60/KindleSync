import SwiftUI
import Foundation
import UserNotifications

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

    private(set) var storedCookies: [HTTPCookie] = []

    private let engine = KindleSyncEngine()
    private let lastSyncKey = "lastSyncDate"
    private let syncIntervalSeconds: TimeInterval = 7 * 24 * 3600 // 7 days

    init() {
        if let cookies = try? CookieKeychainStore.load(),
           !CookieKeychainStore.areCookiesExpired(cookies) {
            storedCookies = cookies
            isAuthenticated = true
        } else {
            isAuthenticated = false
        }
        startScheduler()
    }

    private func startScheduler() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                checkAndSchedule()
            }
        }
    }

    func handleLoginSuccess(_ cookies: [HTTPCookie]) {
        do {
            try CookieKeychainStore.save(cookies)
        } catch {
            print("[KindleSync] Warning: Keychain save failed — \(error.localizedDescription). Session will work this run but won't persist after restart.")
        }
        storedCookies = cookies
        isAuthenticated = true
        checkAndSchedule()
    }

    func logOut() {
        CookieKeychainStore.delete()
        storedCookies = []
        isAuthenticated = false
        status = .idle
        clearSyncHistory()
    }

    func sync() async {
        guard status != .syncing else { return }
        status = .syncing
        do {
            let result = try await engine.sync(cookies: storedCookies)
            status = .success(result.completedAt)
            markSyncComplete()
        } catch SyncError.sessionExpired {
            status = .needsAuth
            isAuthenticated = false
            NotificationManager.notifyNeedsAuth()
        } catch {
            status = .failed(error.localizedDescription)
            NotificationManager.notifyFailure(error.localizedDescription)
        }
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
