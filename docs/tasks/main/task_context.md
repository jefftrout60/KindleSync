# Task Context: KindleSync v1.1 — Scheduling & Cover Images

*Generated: 2026-03-07*

---

## Feature Summary

Two independent enhancements to KindleSync (macOS menu bar app):
1. **Auto-sync scheduling** — Weekly / Bi-weekly / Monthly radio picker in the popover. Persists across app launches. Toasts on set/cancel.
2. **Book cover images** — Download and embed Amazon cover art as base64 in Apple Notes. Retroactive migration on first v1.1 launch via `schemaVersion`.

Reference: `docs/tasks/main/concepts/scope.md`

---

## Architecture Patterns

### State Management
- `SyncManager` is `@MainActor final class SyncManager: ObservableObject` — the single source of truth for sync state. All new scheduling state lives here.
- `@Published` properties drive SwiftUI re-renders in `MenuBarContentView` via `@EnvironmentObject var syncManager`.
- User preferences (e.g. selected schedule interval) go in `UserDefaults`, NOT in `SyncStateStore` (which is for sync data).

### Persistence Layers
| What | Where | Format |
|------|-------|--------|
| Sync data (books, highlights, schema version) | `~/Library/Application Support/Kindle Sync/sync_state.json` via `SyncStateStore` | JSON via `Codable` |
| User preferences (schedule interval, next fire date) | `UserDefaults.standard` | Simple key/value |
| Auth cookies | Keychain via `CookieKeychainStore` | Keychain item |

### Notification Pattern
`NotificationManager.notify(title:body:identifier:)` — delivers via `UNUserNotificationCenter` immediately (trigger = nil). Already used for failure and auth notifications. Add convenience methods for schedule events following the same pattern.

### Note Writing Flow
`KindleSyncEngine.sync()` → `SyncStateStore.merge()` → `NoteFormatter.buildHTML(book:)` → `AppleNotesWriter.upsert(noteTitle:htmlBody:)`

`NoteFormatter` is pure (no I/O). Image data must be downloaded upstream and passed in.

`AppleNotesWriter.upsert()` writes HTML body to a temp file and runs it through `osascript`. HTML content (including base64 `<img>` tags) is fully supported.

### App Entry Point
`KindleSyncApp.swift` (`@main`): creates `SyncManager` as `@StateObject`, injects into `MenuBarContentView` via `.environmentObject()`. The `init()` calls `SMAppService.mainApp.register()` for launch-at-login. `.task {}` on the scene requests notification permission. **This is where launch-time migration should be triggered.**

---

## Dependencies (Key Files)

| File | Role | Changes for v1.1 |
|------|------|------------------|
| `KindleSync/App/KindleSyncApp.swift` | App entry point | Trigger cover image migration at launch (`.task`) |
| `KindleSync/App/SyncManager.swift` | State + sync orchestration | Add scheduler (`Timer`), UserDefaults prefs, migration call |
| `KindleSync/UI/MenuBarContentView.swift` | Popover UI | Add schedule `Picker(.radioGroup)`, next sync display, `.alert` for first-sync prompt |
| `KindleSync/Sync/KindleWebFetcher.swift` | WKWebView JS fetch | Add `productUrl` extraction to JS; add `coverImageURL` to `JSBook` + `KindleBook` |
| `KindleSync/Sync/KindleModels.swift` | Data transfer models | Add `coverImageURL: String?` to `KindleBook` |
| `KindleSync/Sync/SyncStateModels.swift` | Persisted data models | Add `coverImageURL: String?` to `StoredBook`; add `schemaVersion: Int` to `SyncState` |
| `KindleSync/Sync/SyncStateStore.swift` | JSON persistence | No changes expected — schema evolution handled by Codable defaults |
| `KindleSync/Sync/KindleSyncEngine.swift` | Sync orchestration | Download cover images before note writes; migration pass for schemaVersion < 2 |
| `KindleSync/Notes/NoteFormatter.swift` | HTML builder | Accept optional `coverImageBase64: String?`; insert `<img>` tag after header |
| `KindleSync/Utilities/NotificationManager.swift` | System notifications | Add `notifyScheduleSet(interval:nextDate:)` and `notifyScheduleCancelled()` |

**Unchanged:** `CookieKeychainStore.swift`, `AppleNotesWriter.swift`, `AmazonAuthView.swift`

---

## Implementation Approaches

### Feature 1: Auto-Sync Scheduling

**Timer**: Use `Foundation.Timer` in `SyncManager`. For weekly/monthly intervals, `Timer` drift is negligible. `DispatchSourceTimer` is overkill here.

**State in SyncManager:**
```swift
enum SyncInterval: String, CaseIterable {
    case weekly = "weekly"
    case biweekly = "biweekly"
    case monthly = "monthly"
    var weeks: Double { switch self { case .weekly: 1; case .biweekly: 2; case .monthly: 4 } }
    var displayName: String { switch self { case .weekly: "Weekly"; case .biweekly: "Bi-weekly"; case .monthly: "Monthly" } }
}

@Published var scheduleInterval: SyncInterval? = nil   // nil = off
@Published var nextScheduledSync: Date? = nil
private var scheduledTimer: Timer? = nil
```

**Persistence in UserDefaults:**
```swift
// Save
UserDefaults.standard.set(interval.rawValue, forKey: "syncInterval")
UserDefaults.standard.set(nextDate.timeIntervalSince1970, forKey: "nextScheduledSync")
// Load (in SyncManager.init())
if let raw = UserDefaults.standard.string(forKey: "syncInterval"),
   let interval = SyncInterval(rawValue: raw) { ... }
```

**Timer setup:** On schedule set or app launch with existing schedule, arm a one-shot `Timer` to fire at `nextScheduledSync`. When it fires, call `sync()` and re-arm for the next interval. Use `Timer.scheduledTimer(fire:interval:repeats:block:)` with `repeats: false` — re-arm manually after each sync so the next fire time is relative to the *actual* sync completion, not the previous fire time.

**"First sync now?" prompt:** Store `@State var showFirstSyncPrompt = false` in `MenuBarContentView`. When schedule is selected and `status == .idle` (no prior sync), set this to true. Use `.alert(isPresented:)` — native macOS confirmation alert.

**UI in MenuBarContentView:**
```swift
Picker("Auto-sync", selection: $syncManager.scheduleInterval) {
    Text("Off").tag(SyncInterval?.none)
    ForEach(SyncInterval.allCases, id: \.self) { interval in
        Text(interval.displayName).tag(SyncInterval?.some(interval))
    }
}
.pickerStyle(.radioGroup)
```

### Feature 2: Cover Images

**Cover image URL from API:**
The `/kindle-library/search` API `itemsList[]` returns a `productUrl` field: `"https://m.media-amazon.com/images/I/51+7sA25W-L._SY300_.jpg"`. Strip the size modifier to get full resolution: `productUrl.replacingOccurrences(of matching: /\._[A-Z0-9,]+_\.jpg$/, with: ".jpg")`.

**JS change in `KindleWebFetcher.swift`:**
```javascript
// In fetchBooks() return mapping:
books: bks.map(b => ({
    asin: b.asin || '',
    title: b.title || '',
    authors: Array.isArray(b.authors) ? b.authors.join(', ') : (b.authors || ''),
    coverImageURL: b.productUrl
        ? b.productUrl.replace(/\._[A-Z0-9,]+_\.jpg$/, '.jpg')
        : null
}))
```

**Model changes (backward-compatible Codable):**
```swift
// KindleBook (transient, not persisted):
struct KindleBook { ...; var coverImageURL: String? }

// StoredBook (persisted in sync_state.json):
struct StoredBook: Codable {
    ...; var coverImageURL: String?  // nil=not yet fetched, ""=no image, "url"=has image
}

// SyncState:
struct SyncState: Codable {
    var books: [String: StoredBook]
    var schemaVersion: Int          // default 1; v1.1 migration sets to 2
    init() { books = [:]; schemaVersion = 1 }
}
```

**Image download in KindleSyncEngine** (before calling NoteFormatter):
```swift
// Download cover image and encode as base64
private func fetchCoverImageBase64(url: String) async -> String? {
    guard !url.isEmpty, let imageURL = URL(string: url) else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: imageURL) else { return nil }
    return "data:image/jpeg;base64," + data.base64EncodedString()
}
```

**NoteFormatter change:**
```swift
// buildHTML now accepts optional cover image data
static func buildHTML(book: StoredBook, coverImageBase64: String? = nil) -> String {
    var parts: [String] = []
    parts.append("<h2>\(escape(book.title))</h2>")
    parts.append("<p>\(escape(book.author))</p>")
    if let imgData = coverImageBase64 {
        parts.append("<img src=\"\(imgData)\" style=\"max-width:150px;\">")
    }
    parts.append("<p><i>...</i></p>")
    parts.append("<hr>")
    // highlights...
}
```

**Migration via schemaVersion:**
- `SyncState` loads with `schemaVersion`. Old JSON files (no schemaVersion field) decode to default value → we need `schemaVersion` to default to `1` on old data, but we want migration to run for them. Use `schemaVersion: Int = 0` as default (so old files without the field decode to 0, triggering migration) and set to 2 after migration.
- On sync, if `existing.schemaVersion < 2`: after writing notes for books with new highlights, ALSO write notes for all remaining books (to add cover images). Set `schemaVersion = 2` before saving.
- This means migration happens transparently on the first sync after updating to v1.1. No separate UI needed.

**Why schemaVersion defaults to 0 (not 1):**
```swift
struct SyncState: Codable {
    var books: [String: StoredBook]
    var schemaVersion: Int = 0   // 0 = pre-v1.1 (needs migration), 2 = v1.1 migrated
    init() { books = [:]; schemaVersion = 0 }  // fresh install starts at 0 too — migration pass is harmless on empty state
}
```

---

## Impact Summary

### Scheduling
- +1 enum `SyncInterval` (new, in `SyncManager.swift`)
- +3 properties to `SyncManager` (`scheduleInterval`, `nextScheduledSync`, `scheduledTimer`)
- +2 methods to `NotificationManager`
- UI: `Picker` + `Text("Next sync: ...")` + `.alert` in `MenuBarContentView`
- UserDefaults: 2 keys (`syncInterval`, `nextScheduledSync`)

### Cover Images
- JS: +1 field extraction in `kindleFetchScript`
- +1 field to `KindleBook` (transient model)
- +2 fields to `SyncState` + `StoredBook` (persisted models, backward compatible)
- +1 async method to `KindleSyncEngine` (image download)
- Migration path: one extra loop in `KindleSyncEngine.sync()` when `schemaVersion < 2`
- `NoteFormatter.buildHTML()` gets an optional parameter (backward compatible)

---

## External Research

### Kindle Library API
- Endpoint: `GET /kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50`
- Cover image field: **`productUrl`** in each `itemsList[]` item
- URL format: `https://m.media-amazon.com/images/I/{imageId}._SY300_.jpg`
- Strip modifier for full-res: replace `._[A-Z0-9,]+_.jpg` with `.jpg`
- Field can be null/absent for samples, periodicals — guard against this
- Sources: [jkubecki gist](https://gist.github.com/jkubecki/d61d3e953ed5c8379075b5ddd8a95f22), [Xetera/kindle-api](https://github.com/Xetera/kindle-api)

### macOS Scheduling
- `Foundation.Timer.scheduledTimer(fire:interval:repeats:block:)` with `repeats: false` — re-arm after each sync completion
- Must be created on `@MainActor` (SyncManager is already `@MainActor`) so runs on main run loop
- Persist `nextScheduledSync` date to UserDefaults to survive app relaunch; re-arm on init

### Image Embedding
- `URLSession.shared.data(from: url)` — async, no extra imports
- `data.base64EncodedString()` — built into Foundation
- `<img src="data:image/jpeg;base64,{string}" style="max-width:150px;">` — valid HTML for Notes
- Base64 for a typical book cover (~150KB image) is ~200KB of text — acceptable per note

### Apple Notes External Images
- Confirmed via testing (2026-03-07): Apple Notes **blocks** external `<img src="url">` URLs
- Base64 data URIs (`data:image/jpeg;base64,...`) **work** — embed at sync time
