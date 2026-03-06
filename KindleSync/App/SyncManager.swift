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

@MainActor
final class SyncManager: ObservableObject {
    @Published var status: SyncStatus = .idle
    @Published var isAuthenticated: Bool = false

    private let engine = KindleSyncEngine()
    private let webFetcher = KindleWebFetcher()

    init() {
        if let cookies = try? CookieKeychainStore.load(),
           !CookieKeychainStore.areCookiesExpired(cookies) {
            isAuthenticated = true
        } else {
            isAuthenticated = false
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
}
