---
name: feature-kindlesync-architecture
description: Use when working on KindleSync — understanding the sync pipeline, auth flow, data models, or any component of the app.
user-invocable: false
---

# KindleSync Architecture

**Trigger**: kindlesync, kindle sync, sync pipeline, apple notes, kindlewebfetcher, syncengine
**Confidence**: high
**Created**: 2026-03-06
**Updated**: 2026-03-06
**Version**: 1

## What is KindleSync?

KindleSync is a macOS MenuBarExtra app that extracts Kindle highlights from Amazon's notebook page via WKWebView JavaScript injection and writes them to Apple Notes as HTML-formatted notes via AppleScript. It deduplicates highlights across syncs using a JSON state file.

Amazon's Kindle notebook page (`read.amazon.com/notebook`) renders highlights client-side with no public API, so highlights are extracted by injecting JS into a WKWebView after the user authenticates via the real Amazon login flow.

## Sync Pipeline (the main flow)

```
SyncManager.sync()
  → KindleSyncEngine.sync(fetcher:)   [actor]
      → KindleWebFetcher.fetchBooks() + fetchHighlights()  [JS injection into WKWebView]
      → SyncStateStore.merge(existing:newBooks:newHighlightsByASIN:)
      → AppleNotesWriter.upsert(noteTitle:htmlBody:)  [osascript per book]
  → SyncManager updates @Published status
```

## Auth Flow

1. `AmazonAuthView` presents a `WKWebView` pointed at Amazon's login page
2. User logs in normally (including 2FA)
3. A `WKNavigationDelegate` fires on successful navigation, extracts cookies from `WKHTTPCookieStore`
4. `CookieKeychainStore.save()` persists session cookies to Keychain
5. On app launch, `CookieKeychainStore.load()` + `areCookiesExpired()` determines auth state

## Key Files

| File | Purpose |
|------|---------|
| `KindleSync/App/SyncManager.swift` | @MainActor ObservableObject — owns `SyncStatus`, `isAuthenticated`, calls `KindleSyncEngine` |
| `KindleSync/Sync/KindleSyncEngine.swift` | actor — orchestrates full sync: fetch → merge → write notes |
| `KindleSync/Sync/KindleWebFetcher.swift` | Injects JS into WKWebView to scrape books + highlights from read.amazon.com/notebook |
| `KindleSync/Sync/SyncStateStore.swift` | Merge/dedup logic + JSON persistence at `~/Library/Application Support/Kindle Sync/sync_state.json` |
| `KindleSync/Sync/SyncStateModels.swift` | `SyncState`, `StoredBook`, `StoredHighlight`, `SyncError` data types |
| `KindleSync/Sync/NoteFormatter.swift` | Builds HTML string from a `StoredBook` — sorts highlights by `locationNumber()` parsed from location string |
| `KindleSync/Notes/AppleNotesWriter.swift` | Writes HTML body to temp file, runs osascript via `Process` to upsert into Notes |
| `KindleSync/Auth/CookieKeychainStore.swift` | Saves/loads/checks session cookies (`session-token`, `session-id`) in Keychain |
| `KindleSync/Scheduler/SyncScheduler.swift` | `DispatchSourceTimer` that fires `SyncManager.sync()` on interval |
| `KindleSync/UI/MenuBarContentView.swift` | SwiftUI popover — shows sync status, "Sync Now" button, "Log Out" |

## State Persistence

- Sync state lives at: `~/Library/Application Support/Kindle Sync/sync_state.json`
- Format: `SyncState` → `[String: StoredBook]` keyed by ASIN
- `StoredBook.highlightIds` (a `Set<String>`) drives deduplication in `merge()`
- On first run (file absent), `SyncStateStore.load()` returns empty `SyncState()` — not an error

## Highlight Sort Order

Notes sort highlights by `locationNumber()` — a function that parses the integer from strings like `"Location 142"`. This is NOT the same as `startPosition` (which can differ). Location string is preferred; if `locationValue` is empty from the API, it falls back to `"Location \(startPosition)"`.

## Log Out Behavior

`SyncManager.logOut()` does three things:
1. Deletes Keychain entry
2. Wipes all WKWebView data (clears Amazon session cookies from the browser store)
3. Re-injects "long-lived device-trust cookies" (non-session cookies expiring > 30 days) so 2FA isn't required every login

## Common Tasks

**Add a new field to highlights:**
1. Add to `StoredHighlight` in `SyncStateModels.swift`
2. Map it in `SyncStateStore.merge()` (both new-book and existing-book paths)
3. Use it in `NoteFormatter.buildHTML(book:)`
4. Add a test in `SyncStateStorePersistenceTests` for round-trip persistence

**Change the sync schedule:**
Edit `SyncScheduler.swift` — it holds the `DispatchSourceTimer` interval.

**Change the Apple Notes folder name:**
Edit `AppleNotesWriter.upsertScript()` — the string `"Kindle Highlights"` appears in the AppleScript.
