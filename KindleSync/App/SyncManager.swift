import SwiftUI
import Foundation
import WebKit

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case failed(String)
    case needsAuth
}

enum SyncInterval: String, CaseIterable, Identifiable {
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .weekly:   return 1 * 7 * 24 * 3600
        case .biweekly: return 2 * 7 * 24 * 3600
        case .monthly:  return 4 * 7 * 24 * 3600
        }
    }

    var displayName: String {
        switch self {
        case .weekly:   return "Weekly"
        case .biweekly: return "Bi-weekly"
        case .monthly:  return "Monthly"
        }
    }
}

@MainActor
final class SyncManager: ObservableObject {
    @Published var status: SyncStatus = .idle
    @Published var isAuthenticated: Bool = false
    @Published var scheduleInterval: SyncInterval? = nil
    @Published var nextScheduledSync: Date? = nil
    private var scheduledTimer: Timer? = nil

    private enum DefaultsKey {
        static let interval = "syncInterval"
        static let nextFire = "nextScheduledSync"
    }

    var lastSyncDate: Date? {
        if case .success(let date) = status { return date }
        return nil
    }

    private let engine = KindleSyncEngine()
    private let webFetcher = KindleWebFetcher()

    init() {
        if let cookies = try? CookieKeychainStore.load(),
           !CookieKeychainStore.areCookiesExpired(cookies) {
            isAuthenticated = true
        } else {
            isAuthenticated = false
        }

        // Restore schedule persisted across quit/relaunch
        if let raw = UserDefaults.standard.string(forKey: DefaultsKey.interval),
           let interval = SyncInterval(rawValue: raw) {
            let nextFireTimestamp = UserDefaults.standard.double(forKey: DefaultsKey.nextFire)
            if nextFireTimestamp != 0 {
                scheduleInterval = interval
                let nextFireDate = Date(timeIntervalSince1970: nextFireTimestamp)
                armTimer(for: nextFireDate, interval: interval)
            }
        }
    }

    func handleLoginSuccess(_ cookies: [HTTPCookie]) {
        do {
            try CookieKeychainStore.save(cookies)
        } catch {
            print("[KindleSync] Warning: Keychain save failed — \(error.localizedDescription). Session will work this run but won't persist after restart.")
        }
        isAuthenticated = true
    }

    func logOut() {
        CookieKeychainStore.delete()
        // Preserve long-lived cookies (e.g. Amazon device-trust set by "don't require a
        // code on this browser") so 2FA isn't required after every explicit logout.
        // Session cookies are cleared with the full data-store wipe below.
        let store = WKWebsiteDataStore.default()
        store.httpCookieStore.getAllCookies { trustCookies in
            // Keep long-lived device-trust cookies but never keep session credentials.
            // Amazon's session-token can have a multi-month expiry, so expiry alone
            // is not enough to distinguish trust cookies from session cookies.
            let sessionCookieNames: Set<String> = ["session-token", "session-id",
                                                    "at-main", "at-acbus"]
            let longLived = trustCookies.filter { cookie in
                guard !sessionCookieNames.contains(cookie.name),
                      let expires = cookie.expiresDate else { return false }
                return expires.timeIntervalSinceNow > 30 * 24 * 3600 // > 30 days
            }
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                // Re-inject trust cookies after the wipe
                for cookie in longLived {
                    store.httpCookieStore.setCookie(cookie) { }
                }
            }
        }
        isAuthenticated = false
        status = .idle
    }

    func sync() async {
        guard status != .syncing else { return }
        status = .syncing
        do {
            let result = try await engine.sync(fetcher: webFetcher)
            status = .success(result.completedAt)
            // Re-arm the schedule timer from the completion time
            if let current = scheduleInterval {
                armTimer(for: Date().addingTimeInterval(current.seconds), interval: current)
            }
        } catch SyncError.sessionExpired {
            status = .needsAuth
            isAuthenticated = false
            NotificationManager.notifyNeedsAuth()
        } catch SyncError.alreadyInProgress {
            // Another sync is in progress — silently ignore
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
            NotificationManager.notifyFailure(error.localizedDescription)
        }
    }

    func setSchedule(_ interval: SyncInterval?, notify: Bool = true) {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        scheduleInterval = interval
        guard let interval else {
            nextScheduledSync = nil
            UserDefaults.standard.removeObject(forKey: DefaultsKey.interval)
            UserDefaults.standard.removeObject(forKey: DefaultsKey.nextFire)
            if notify { NotificationManager.notifyScheduleCancelled() }
            return
        }
        let base = lastSyncDate ?? Date()
        let next = base.addingTimeInterval(interval.seconds)
        armTimer(for: next, interval: interval)
        if notify { NotificationManager.notifyScheduleSet(interval: interval, nextDate: next) }
    }

    private func armTimer(for date: Date, interval: SyncInterval) {
        nextScheduledSync = date
        UserDefaults.standard.set(interval.rawValue, forKey: DefaultsKey.interval)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: DefaultsKey.nextFire)
        let delay = max(0, date.timeIntervalSinceNow)
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.sync()
            }
        }
    }
}
