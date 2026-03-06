# KindleSync Architecture Review
*Date: 2026-03-06*

## Executive Summary

KindleSync is a well-structured macOS menu bar app with clean layering across ~14 source files. The architecture follows a sensible App -> Manager -> Engine -> Services hierarchy, and recent commits show thoughtful iteration (injecting URLSession for testability, fixing deduplication, silencing benign errors). The main risks are around the WKWebView/continuation lifecycle in `KindleWebFetcher`, missing corruption recovery for `sync_state.json`, and the fact that state is persisted even when Apple Notes writes fail -- which means highlights can be "lost" (recorded as synced but never actually written to Notes).

## Strengths

- **Clean separation of concerns.** `SyncManager` (UI state) -> `KindleSyncEngine` (orchestration actor) -> `KindleWebFetcher`/`AppleNotesWriter`/`SyncStateStore` (I/O services). No layer reaches more than one level down.
- **Actor-based sync engine.** `KindleSyncEngine` is an `actor`, which gives thread-safe `isSyncing` guarding for free without manual locking.
- **Deterministic highlight IDs.** Using `asin#fnv32a(text+location)` as the highlight ID means deduplication works across sessions without needing server-side IDs.
- **Atomic file writes.** `SyncStateStore.save` uses `.atomicWrite`, preventing half-written state files on crash.
- **Keychain for credentials.** Session cookies are stored in Keychain (not UserDefaults or files), which is the correct choice for sensitive auth material on macOS.
- **Good HTML escaping.** `NoteFormatter.escape()` handles `&`, `<`, `>`, and `"` -- the four characters needed for safe HTML interpolation.
- **Thoughtful logout flow.** The `logOut()` method preserves long-lived device-trust cookies (so users don't have to re-do 2FA every time) while clearing session credentials.
- **Solid test coverage for pure logic.** `SyncStateStore.merge`, `NoteFormatter.buildHTML`, `CookieKeychainStore` encode/decode/expiry, and state persistence round-trip are all tested. These are the right things to test first.
- **Good error taxonomy.** `SyncError` covers all the meaningful failure modes (session expired, network, decoding, notes, permission, already in progress) with user-facing `LocalizedError` descriptions.

## Issues by Severity

### Critical

**1. State saved before Notes writes complete -- highlights silently lost on partial failure**

In `KindleSyncEngine.sync()` (line 57), state is persisted *after* the Notes-writing loop, but the loop itself continues past individual book failures (the `catch` on line 51 just prints and increments `notesFailureCount`). When `save(updatedState)` runs on line 57, the merged state includes highlights for books whose Notes write failed. On the next sync, those highlights will already exist in `SyncState`, so `merge()` will not include them in `addedByASIN`, and they will never be written to Apple Notes.

The comment on line 56 says "failed Notes writes will get re-attempted on next full rebuild" but there is no rebuild mechanism in the codebase. This is the most impactful bug -- users lose highlights silently.

*Fix: Either (a) only save state for books whose Notes write succeeded, or (b) track a `writtenToNotes: Bool` flag per book in `SyncState` and retry unwritten books on every sync.*

**2. `loadContinuation` can be resumed twice on navigation failure**

In `KindleWebFetcher`, the `WKNavigationDelegate` methods (`didFinish`, `didFail`, `didFailProvisionalNavigation`) each resume and nil out `self.loadContinuation`. However, WebKit can call `didFinish` after `didFailProvisionalNavigation` in some redirect scenarios, or call `didFail` after the page has already triggered `didFinish`. If `loadContinuation` is nil by that point, the nil-check protects against a crash, but the *first* scenario -- where two delegate methods fire in quick succession before the `Task { @MainActor }` block executes -- could theoretically resume the continuation twice, which is a fatal runtime error (`CheckedContinuation` traps on double-resume).

*Fix: Use a dedicated flag (e.g., `private var continuationResumed = false`) that is checked-and-set atomically within each delegate callback's `@MainActor` block.*

**3. `areCookiesExpired` logic inverted for session cookies without expiry dates**

In `CookieKeychainStore.areCookiesExpired` (line 77), the method returns `true` (expired) only when `allSatisfy` returns `true` -- i.e., when *every* relevant cookie's `expires < now`. But the closure returns `false` for cookies with no `expiresDate` (line 78: `guard let expires = cookie.expiresDate else { return false }`). This means a session cookie with no expiry date causes `allSatisfy` to return `false`, which means `areCookiesExpired` returns `false` (not expired). This is arguably correct (session cookies without expiry are valid for the browser session), but it means: if all stored cookies lack expiry dates, the app will consider itself authenticated forever, even after the server has actually expired the session. The test `testAreCookiesExpired_returnsFalse_whenSessionCookieHasNoExpiresDate` codifies this behavior, but it is a latent correctness risk for real-world Amazon cookies.

### Medium

**4. No recovery from corrupted `sync_state.json`**

`SyncStateStore.load()` calls `JSONDecoder().decode(SyncState.self, from: data)` with no `catch`. If the file exists but is malformed JSON (e.g., truncated by a prior crash before atomic write completes, or manually edited), the app throws and sync fails permanently until the user manually deletes the file. There is no fallback, no backup, and no user-facing guidance.

*Fix: Wrap the decode in a do/catch that logs the error and returns an empty `SyncState()`, possibly after backing up the corrupted file.*

**5. `KindleWebFetcher` is `@MainActor` -- blocks main thread during sync**

`KindleWebFetcher` is marked `@MainActor` because `WKWebView` requires main-thread access. While the `await` points in `fetchAll()` yield back to the caller, the JavaScript execution (`callAsyncJavaScript`) and HTML parsing happen on WebKit's internal threads. The real concern is that `KindleSyncEngine` is an `actor` that calls `fetcher.fetchAll()`, which requires a hop to `@MainActor`. During the fetch (which involves network requests for every book), the engine actor's `isSyncing` guard is held, but the main actor is yielded between awaits. This is correct but means the UI remains responsive -- good. However, if a future change adds synchronous work to the fetcher, it will block the UI.

**6. No scheduled/automatic sync**

The git log mentions a "scheduler" commit, but the `SyncScheduler` file no longer exists (it was removed or moved). There is no automatic periodic sync -- users must manually click "Sync Now." For an MVP this is fine, but the menu bar app paradigm implies background syncing. The `SMAppService.mainApp.register()` call in `KindleSyncApp.init()` registers for login-item launch, but there is nothing that triggers a sync on launch or on a timer.

*Consider: Add a simple `Timer.publish` or `Task.sleep` loop in `SyncManager` that syncs on app launch and every N hours.*

**7. `NoteFormatter` hardcodes "Jeff's Note:" label**

`NoteFormatter.swift` line 24 contains the hardcoded string `"Jeff's Note:"`. This is fine for a personal app but would need parameterization for distribution.

**8. AppleScript note matching is fragile**

In `AppleNotesWriter.upsertScript()`, the note is found by matching on `name`: `set matchingNotes to (every note whose name is noteName)`. Apple Notes derives the note's `name` from the first line of the body, not from a stable identifier. If the user manually edits the note title in Apple Notes, the match will fail and a duplicate note will be created on the next sync. Additionally, `every note whose name is noteName` searches across all accounts/folders, but `make new note at targetFolder` creates in a specific folder -- so after the first sync, if the user moves the note to a different folder, updates still work (good), but this cross-account search could match notes in iCloud vs. local accounts unexpectedly.

**9. `logOut()` has a subtle race with async cookie operations**

In `SyncManager.logOut()`, `isAuthenticated` is set to `false` on line 66, but the `WKWebsiteDataStore` operations (lines 44-64) are callback-based and asynchronous. If the user quickly logs out and then the auth sheet appears and they start logging in, the `removeData` completion handler (line 56) could fire and wipe the new session's cookies. This is unlikely but possible with fast user interaction.

**10. No sync-in-progress UI feedback beyond "Syncing..."**

For a library with many books, the sync can take minutes (500ms delay per book in the JS). The UI shows only "Syncing..." with a spinner. There is no progress indicator, no book count, and no way to cancel. Users may think the app is stuck.

### Low / Future

**11. `KindleWebFetcher` creates a new `WKWebView` per sync**

Each call to `fetchAll()` creates a fresh `WKWebView`. This means cookies must be loaded from the shared `WKWebsiteDataStore` each time. This works correctly but is wasteful -- reusing a single web view would avoid re-initialization overhead. However, the `defer { self.webView = nil }` cleanup pattern is clean and avoids memory leaks, so this is a reasonable trade-off for simplicity.

**12. No retry logic for transient network failures**

If a single book's highlight fetch fails (e.g., HTTP 500 from Amazon), the entire `fetchAll()` throws. There is no per-book retry or graceful degradation. The JS `fetchHighlights` function breaks out of the pagination loop on `!r.ok` but does not throw -- it just returns whatever highlights were fetched so far for that book. The `fetchBooks` function does throw on HTTP errors. This inconsistency means: book-list fetch failure = total failure; individual book highlight fetch failure = silent partial data.

**13. Tests use real Keychain and real filesystem**

`CookieKeychainStoreTests` calls the real `SecItemAdd`/`SecItemDelete` Keychain APIs, and `SyncStateStorePersistenceTests` reads/writes the real Application Support directory. These are integration tests, not unit tests. They will fail in CI without a Keychain, and they mutate shared state that could interfere with a running instance of the app.

**14. No test for `KindleSyncEngine`, `KindleWebFetcher`, or `AppleNotesWriter`**

The core orchestration layer and all I/O layers are untested. `KindleSyncEngine.sync()` takes a concrete `KindleWebFetcher` -- there is no protocol, so it cannot be stubbed. Same for `AppleNotesWriter` (static methods, no protocol) and `SyncStateStore` (static methods, no protocol).

**15. `DateFormatter` created on every `formattedTime` call in `MenuBarContentView`**

Line 90 of `MenuBarContentView.swift` creates a new `DateFormatter()` on every call. `DateFormatter` is expensive to create. This is a minor performance issue since it only runs on status changes, but it is a common Swift anti-pattern.

**16. No Keychain access control**

The Keychain item is stored with default access control -- any process running as the same user can read it. For a personal app this is fine, but for distribution, adding `kSecAttrAccessControl` with `.whenUnlockedThisDeviceOnly` or similar would be more secure.

## Testability Assessment

**Currently testable (and tested):**
- `NoteFormatter.buildHTML` -- pure function, no dependencies. 2 tests.
- `SyncStateStore.merge` -- pure function, no I/O. 4 tests.
- `CookieKeychainStore.areCookiesExpired` -- pure logic on input cookies. 4 tests.
- `CookieKeychainStore` save/load/delete -- integration tests against real Keychain. 2 tests.
- `SyncStateStore` save/load persistence -- integration tests against real filesystem. 2 tests.

**Not testable (and why):**
- `KindleSyncEngine.sync()` -- takes a concrete `KindleWebFetcher` (no protocol). Cannot inject a mock fetcher. Also calls `AppleNotesWriter` and `SyncStateStore` as static methods with no injection point.
- `KindleWebFetcher.fetchAll()` -- requires a real `WKWebView` and network access. `@MainActor` constraint makes it hard to test outside a running app. No protocol abstraction.
- `AppleNotesWriter` -- executes real AppleScript via `Process`/`osascript`. No protocol, no injection, no way to mock.
- `SyncManager` -- depends on concrete `KindleSyncEngine` and `KindleWebFetcher` with no injection. Also depends on `CookieKeychainStore` static methods.
- `AmazonAuthView` -- UI component wrapping `WKWebView`. Would require UI testing framework.

**What would make untestable parts testable:**
1. Define protocols for the three I/O boundaries: `HighlightFetching`, `NoteWriting`, `StateStoring`.
2. Have `KindleSyncEngine.sync()` accept these as parameters (or inject via init).
3. Create mock implementations for tests that return canned data or record calls.
4. This would allow testing the full sync pipeline (merge logic, error handling, partial failure) without network, Keychain, or AppleScript.

## Recommendations

Prioritized list of next steps:

1. **Fix the "lost highlights" bug (Critical #1).** Track which books have been successfully written to Notes in `SyncState`. On each sync, retry any books marked as unwritten. This is the highest-impact correctness issue.

2. **Guard against double continuation resume (Critical #2).** Add a `continuationResumed` flag in `KindleWebFetcher`'s delegate methods. This prevents a potential fatal crash.

3. **Add corruption recovery for `sync_state.json` (Medium #4).** Catch decode errors in `SyncStateStore.load()` and fall back to empty state (with a backup of the corrupted file and a logged warning).

4. **Extract protocols for I/O boundaries (Low #14).** Define `HighlightFetching`, `NoteWriting`, and `StateStoring` protocols. This unblocks unit testing of `KindleSyncEngine` and is the single highest-leverage testability improvement.

5. **Add automatic sync on launch and on a timer (Medium #6).** A simple periodic sync (e.g., every 6 hours) would make the menu bar app feel like it "just works" rather than requiring manual intervention.

6. **Add progress reporting during sync (Medium #10).** Pass a progress callback or publish progress updates so the UI can show "Syncing book 3 of 47..." instead of just "Syncing...".

7. **Harden the AppleScript note matching (Medium #8).** Consider using a unique identifier (e.g., embedding the ASIN in the note body as a hidden marker) rather than relying on note name matching, which can break if the user renames the note.

8. **Move integration tests behind a test plan flag (Low #13).** Keychain and filesystem tests should be gated so they do not run in CI environments without proper entitlements.
