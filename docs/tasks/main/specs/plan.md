# Implementation Plan: KindleSync v1.1 — Scheduling & Cover Images

*Created: 2026-03-07 | Depth: Standard*

---

## Overview

Two independent features added to the existing KindleSync macOS menu bar app:

1. **Auto-sync scheduling** — A `Picker(.radioGroup)` in the popover lets users set Weekly / Bi-weekly / Monthly automatic syncs. Persists across launches via `UserDefaults`. System notification toasts confirm set/cancel. If the scheduled time has passed when the app relaunches, sync fires immediately.

2. **Book cover images in Apple Notes** — During sync, the cover image URL (`productUrl` field from the Kindle library API) is captured, the image is downloaded and embedded as base64 in the note HTML. Migration pass runs transparently on the first sync after updating to v1.1 — rewrites all existing notes to add cover images without requiring any user action.

---

## Desired End State

### Scheduling
- `SyncManager` owns a `SyncInterval?` selection and a `Timer` that fires sync on schedule
- Interval and next-fire date persisted in `UserDefaults`; re-armed on every app launch
- If next-fire date is in the past at launch → sync immediately, re-arm for next interval
- `MenuBarContentView` shows: radio picker (Weekly / Bi-weekly / Monthly / Off), next sync date when active
- System notification banners confirm schedule set and schedule cancelled
- Manual sync ("Sync Now") resets the timer; next sync recalculated from completion

### Cover Images
- `KindleBook` and `StoredBook` carry `coverImageURL: String?`
- JS fetch captures `productUrl` from the Kindle library API (stripped of size modifier)
- During note writes, cover image downloaded via `URLSession` and embedded as `data:image/jpeg;base64,...`
- `NoteFormatter.buildHTML(book:coverImageBase64:)` inserts `<img>` tag between header and highlights
- `SyncState.schemaVersion` starts at `0` for all existing installs; set to `2` after migration
- First sync after v1.1 update rewrites ALL existing notes with cover images (migration pass), then sets `schemaVersion = 2`

---

## Out of Scope

- Time-of-day scheduling (schedule fires relative to last sync, not a clock target)
- Background syncing when app is not running
- Persisting cover image base64 data to disk (re-downloaded each note write)
- Placeholder/fallback UI for missing covers
- Sub-weekly intervals
- Highlights email feature

---

## Technical Approach

### Part 1 — Auto-Sync Scheduling

#### 1.1 New enum + state in SyncManager

Add `SyncInterval` enum and scheduling state to `SyncManager.swift`:

```swift
enum SyncInterval: String, CaseIterable, Identifiable {
    case weekly, biweekly, monthly
    var id: String { rawValue }
    var weeks: Double {
        switch self { case .weekly: 1; case .biweekly: 2; case .monthly: 4 }
    }
    var displayName: String {
        switch self { case .weekly: "Weekly"; case .biweekly: "Bi-weekly"; case .monthly: "Monthly" }
    }
    var seconds: TimeInterval { weeks * 7 * 24 * 3600 }
}

// In SyncManager:
@Published var scheduleInterval: SyncInterval? = nil
@Published var nextScheduledSync: Date? = nil
private var scheduledTimer: Timer? = nil
```

#### 1.2 UserDefaults persistence keys

```swift
private enum DefaultsKey {
    static let interval = "syncInterval"
    static let nextFire = "nextScheduledSync"
}
```

#### 1.3 Timer management in SyncManager

```swift
func setSchedule(_ interval: SyncInterval?) {
    scheduledTimer?.invalidate()
    scheduledTimer = nil
    scheduleInterval = interval
    guard let interval else {
        nextScheduledSync = nil
        UserDefaults.standard.removeObject(forKey: DefaultsKey.interval)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.nextFire)
        NotificationManager.notifyScheduleCancelled()
        return
    }
    // Calculate next fire from last sync time, or now if no prior sync
    let base = lastSyncDate ?? Date()
    let next = base.addingTimeInterval(interval.seconds)
    armTimer(for: next, interval: interval)
    NotificationManager.notifyScheduleSet(interval: interval, nextDate: next)
}

private func armTimer(for date: Date, interval: SyncInterval) {
    nextScheduledSync = date
    UserDefaults.standard.set(interval.rawValue, forKey: DefaultsKey.interval)
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: DefaultsKey.nextFire)
    let delay = max(0, date.timeIntervalSinceNow)  // fire immediately if past due
    scheduledTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.sync()
            // Re-arm for next interval from completion
            if let current = self.scheduleInterval {
                self.armTimer(for: Date().addingTimeInterval(current.seconds), interval: current)
            }
        }
    }
}
```

**`lastSyncDate`** — a computed property derived from `SyncStatus`:
```swift
var lastSyncDate: Date? {
    if case .success(let date) = status { return date }
    return nil
}
```

#### 1.4 On app launch — restore schedule (in SyncManager.init())

```swift
// After auth check, restore saved schedule:
if let raw = UserDefaults.standard.string(forKey: DefaultsKey.interval),
   let interval = SyncInterval(rawValue: raw) {
    scheduleInterval = interval
    let savedNext = UserDefaults.standard.double(forKey: DefaultsKey.nextFire)
    let nextDate = savedNext > 0 ? Date(timeIntervalSince1970: savedNext) : Date()
    // armTimer handles past-due dates by firing immediately (delay clamped to 0)
    armTimer(for: nextDate, interval: interval)
}
```

#### 1.5 Manual sync resets timer

In `SyncManager.sync()`, after `status = .success(result.completedAt)`:
```swift
if let interval = scheduleInterval {
    armTimer(for: Date().addingTimeInterval(interval.seconds), interval: interval)
}
```

#### 1.6 "First sync now?" prompt

In `MenuBarContentView`, when user selects a non-nil interval AND `syncManager.lastSyncDate == nil`:
```swift
.alert("No sync has been run yet", isPresented: $showFirstSyncPrompt) {
    Button("Sync Now") { Task { await syncManager.sync() } }
    Button("Later", role: .cancel) { }
}
```

#### 1.7 UI additions to MenuBarContentView

Below "Log Out":
```swift
Divider()

Picker("Auto-sync", selection: $syncManager.scheduleInterval) {
    Text("Off").tag(SyncInterval?.none)
    ForEach(SyncInterval.allCases) { interval in
        Text(interval.displayName).tag(SyncInterval?.some(interval))
    }
}
.pickerStyle(.radioGroup)
.onChange(of: syncManager.scheduleInterval) { _, newValue in
    syncManager.setSchedule(newValue)
    if newValue != nil && syncManager.lastSyncDate == nil {
        showFirstSyncPrompt = true
    }
}

if let next = syncManager.nextScheduledSync {
    Text("Next sync: \(formattedDateTime(next))")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

#### 1.8 NotificationManager additions

```swift
static func notifyScheduleSet(interval: SyncInterval, nextDate: Date) {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium; formatter.timeStyle = .short
    notify(
        title: "Kindle Sync scheduled",
        body: "\(interval.displayName) sync enabled. Next: \(formatter.string(from: nextDate))",
        identifier: "com.jeff.kindlesync.scheduleSet"
    )
}

static func notifyScheduleCancelled() {
    notify(
        title: "Kindle Sync schedule cancelled",
        body: "Auto-sync has been turned off.",
        identifier: "com.jeff.kindlesync.scheduleCancelled"
    )
}
```

---

### Part 2 — Cover Images

#### 2.1 Kindle library API — capture `productUrl` in JS

In `KindleWebFetcher.swift`, update the JS return mapping in `kindleFetchScript`:

```javascript
books: bks.map(b => ({
    asin: b.asin || '',
    title: b.title || '',
    authors: Array.isArray(b.authors) ? b.authors.join(', ') : (b.authors || ''),
    coverImageURL: b.productUrl
        ? b.productUrl.replace(/\._[A-Z0-9,]+_\.jpg$/, '.jpg')
        : null
}))
```

Also update `JSBook` struct:
```swift
private struct JSBook: Decodable {
    let asin: String
    let title: String
    let authors: String
    let coverImageURL: String?
}
```

And `KindleBook` model in `KindleModels.swift`:
```swift
struct KindleBook: Identifiable {
    let asin: String
    let title: String
    let authors: String
    var coverImageURL: String?
    var id: String { asin }
}
```

Pass through in `KindleWebFetcher.fetchAll()`:
```swift
let books = jsResult.books.map {
    KindleBook(asin: $0.asin, title: $0.title, authors: $0.authors, coverImageURL: $0.coverImageURL)
}
```

#### 2.2 StoredBook and SyncState model changes

In `SyncStateModels.swift`:

```swift
struct StoredBook: Codable {
    let asin: String
    var title: String
    var author: String
    var highlights: [StoredHighlight]
    var coverImageURL: String?   // nil=not yet fetched, ""=no image available, "url"=has image
    // ... existing computed props unchanged
}

struct SyncState: Codable {
    var books: [String: StoredBook]
    var schemaVersion: Int = 0   // 0 = pre-v1.1 (needs migration); 2 = migrated
    init() { books = [:]; schemaVersion = 0 }
}
```

Both additions are backward-compatible Codable optionals — old JSON files without these fields decode cleanly to `nil` / `0`.

#### 2.3 SyncStateStore.merge() — propagate coverImageURL

In `SyncStateStore.merge()`, when creating or updating a `StoredBook`, copy `coverImageURL` from the fetched `KindleBook`:

```swift
// On new book:
updatedState.books[asin] = StoredBook(
    asin: asin, title: book.title, author: book.authors,
    highlights: allStored,
    coverImageURL: book.coverImageURL   // capture from API
)

// On existing book update:
storedBook.coverImageURL = book.coverImageURL ?? storedBook.coverImageURL
```

#### 2.4 Image download helper in KindleSyncEngine

```swift
private func fetchCoverImageBase64(url: String) async -> String? {
    guard !url.isEmpty, let imageURL = URL(string: url) else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: imageURL) else { return nil }
    return "data:image/jpeg;base64," + data.base64EncodedString()
}
```

#### 2.5 NoteFormatter — optional cover image parameter

```swift
static func buildHTML(book: StoredBook, coverImageBase64: String? = nil) -> String {
    var parts: [String] = []
    parts.append("<h2>\(escape(book.title))</h2>")
    parts.append("<p>\(escape(book.author))</p>")
    parts.append("<p><i>\(count) highlight\(count == 1 ? "" : "s") · Last synced: \(syncDate)</i></p>")
    if let imgData = coverImageBase64 {
        parts.append("<img src=\"\(imgData)\" style=\"max-width:150px;\"><br>")
    }
    parts.append("<hr>")
    // highlights loop unchanged...
}
```

Default parameter = `nil` keeps all existing call sites working without change.

#### 2.6 KindleSyncEngine — image download + migration

In `KindleSyncEngine.sync()`, update the note-write loop to download images:

```swift
// Replace the existing write loop:
for (asin, newHighlights) in addedByASIN where !newHighlights.isEmpty {
    guard let storedBook = updatedState.books[asin] else { continue }
    let coverBase64 = await fetchCoverImageBase64(url: storedBook.coverImageURL ?? "")
    let html = NoteFormatter.buildHTML(book: storedBook, coverImageBase64: coverBase64)
    let title = NoteFormatter.noteTitle(for: storedBook)
    do {
        try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html)
        totalNew += newHighlights.count
        // Mark coverImageURL as confirmed ("" if no image, url if had one)
        updatedState.books[asin]?.coverImageURL = storedBook.coverImageURL ?? ""
    } catch {
        failedASINs.insert(asin)
    }
}
```

**Migration pass** — after normal writes, if `schemaVersion < 2`:

```swift
if existing.schemaVersion < 2 {
    let alreadyWritten = Set(addedByASIN.keys).union(failedASINs)
    for (asin, storedBook) in updatedState.books where !alreadyWritten.contains(asin) {
        let coverBase64 = await fetchCoverImageBase64(url: storedBook.coverImageURL ?? "")
        let html = NoteFormatter.buildHTML(book: storedBook, coverImageBase64: coverBase64)
        let title = NoteFormatter.noteTitle(for: storedBook)
        _ = try? await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html)
        // Best-effort: don't fail the whole sync if a migration write fails
        updatedState.books[asin]?.coverImageURL = storedBook.coverImageURL ?? ""
    }
    updatedState.schemaVersion = 2
}
```

Migration is transparent — no UI indicator needed. It runs once, silently, during the first sync after the update.

---

## Data Model Changes Summary

| Model | Field Added | Default | Backward Compat? |
|-------|------------|---------|-----------------|
| `KindleBook` | `coverImageURL: String?` | `nil` | N/A (transient) |
| `StoredBook` | `coverImageURL: String?` | `nil` | ✅ Codable optional |
| `SyncState` | `schemaVersion: Int` | `0` | ✅ Codable default |
| `SyncManager` | `scheduleInterval`, `nextScheduledSync`, `scheduledTimer` | `nil` | N/A (runtime) |

---

## Critical Files for Implementation

| File | Role |
|------|------|
| `KindleSync/App/SyncManager.swift` | Add `SyncInterval` enum, timer logic, UserDefaults persistence, `setSchedule()`, `armTimer()`, `lastSyncDate` |
| `KindleSync/UI/MenuBarContentView.swift` | Add `Picker(.radioGroup)`, next sync display, `.alert` for first-sync prompt |
| `KindleSync/Sync/KindleSyncEngine.swift` | Add `fetchCoverImageBase64()`, update write loop with image download, add migration pass |
| `KindleSync/Sync/KindleWebFetcher.swift` | Add `coverImageURL` to JS extraction, `JSBook`, `KindleBook` mapping |
| `KindleSync/Sync/SyncStateModels.swift` | Add `coverImageURL` to `StoredBook`, `schemaVersion` to `SyncState` |
| `KindleSync/Notes/NoteFormatter.swift` | Add optional `coverImageBase64` parameter to `buildHTML()` |
| `KindleSync/Utilities/NotificationManager.swift` | Add `notifyScheduleSet()` and `notifyScheduleCancelled()` |
