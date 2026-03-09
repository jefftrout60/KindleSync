# Code Review: KindleSync v1.1 — Scheduling & Cover Images

**Date**: 2026-03-07
**Reviewer**: Independent code review agent
**Scope**: All modified/created files for KindleSync v1.1 (14 tasks across 5 waves)

---

## Summary Assessment

KindleSync v1.1 is clean, well-organized, and follows YAGNI/KISS principles. The implementation closely follows the spec with solid defensive coding patterns. Found **one high-severity issue** (Timer with `timeInterval: 0` behavior on past-due relaunch), **two medium issues**, and several low-severity observations.

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Security Posture | 8/10 | HTML escaping thorough; base64 data URI avoids XSS in Notes; no secrets in UserDefaults; Keychain for cookies. Minor: `coverImageURL` used in `URLSession.data(from:)` without URL validation beyond `URL(string:)`. |
| Logic Correctness | 7/10 | Timer-with-zero-interval edge case for REQ-009; `lastSyncDate` ephemeral after relaunch; migration skip gap. |
| Code Quality | 9/10 | Clean separation of concerns; actor isolation correct; `[weak self]` in timer closures; defensive nil-coalescing in merge. |
| Production Readiness | 7/10 | Timer and `lastSyncDate` issues need resolution. Migration is best-effort as specified. No crashes expected. |

---

## 🚨 Critical Issues

*None.*

---

## 🔥 High-Severity Issues

### H1: `Timer.scheduledTimer(withTimeInterval: 0, ...)` — Problematic for REQ-009

**File:** `KindleSync/App/SyncManager.swift`, line 162

When the app relaunches and the persisted `nextFire` date is in the past, `armTimer` computes:
```swift
let delay = max(0, date.timeIntervalSinceNow) // evaluates to 0
```

A `Timer.scheduledTimer(withTimeInterval: 0, repeats: false)` fires "the next run loop iteration." During `SyncManager.init()` (called from `@StateObject` initialization), this means `sync()` could be invoked before `MenuBarContentView` has subscribed to observe `SyncManager`, causing the UI to miss the `.syncing` status transition.

**Recommendation:** Use `Task.sleep` instead of `Timer` for the scheduled sync, which avoids the `timeInterval: 0` issue entirely (sleeping 0 seconds simply yields) and has a cleaner cancellation model:

```swift
private var scheduledTask: Task<Void, Never>?

private func armTimer(for date: Date, interval: SyncInterval) {
    scheduledTask?.cancel()
    nextScheduledSync = date
    UserDefaults.standard.set(interval.rawValue, forKey: DefaultsKey.interval)
    UserDefaults.standard.set(date.timeIntervalSince1970, forKey: DefaultsKey.nextFire)
    let delay = max(0, date.timeIntervalSinceNow)
    scheduledTask = Task { @MainActor [weak self] in
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        guard !Task.isCancelled, let self else { return }
        await self.sync()
    }
}
```

In `setSchedule()`, replace `scheduledTimer?.invalidate(); scheduledTimer = nil` with `scheduledTask?.cancel(); scheduledTask = nil`.

---

## ⚠️ Medium-Severity Issues

### M1: `lastSyncDate` Is Ephemeral — Lost After Relaunch

**File:** `KindleSync/App/SyncManager.swift`, line 50–53

`status` starts as `.idle` on every launch, so `lastSyncDate` is always `nil` after relaunch. Impact:
1. Schedule next-fire calculation after relaunch uses `Date()` instead of actual last sync date.
2. REQ-005 "First sync now?" alert could fire after relaunch edge cases.

**Recommendation:** Persist `lastSyncDate` in UserDefaults alongside the schedule. Add `static let lastSync = "lastSyncDate"` to `DefaultsKey` and save/restore alongside schedule restoration.

### M2: Migration Rewrites Notes Even With No Cover Image Available

**File:** `KindleSync/Sync/KindleSyncEngine.swift`, lines 83–88

For books where `coverImageURL` is `nil` (pre-v1.1 stored without a URL), migration calls `buildHTML` with `coverBase64 = nil` and rewrites the note anyway. This is per REQ-016 (no placeholder) but causes unnecessary AppleScript calls for notes that won't visually change.

**Recommendation:** Skip the `upsert` call during migration when `coverBase64` is nil AND `storedBook.coverImageURL` is nil (URL was never available, nothing to add):
```swift
// Skip migration for books with no cover URL — nothing to add
if storedBook.coverImageURL == nil { continue }
```

---

## 💡 Low-Severity Issues

### L1: Schedule Dies Silently on Sync Failure

**File:** `KindleSync/App/SyncManager.swift`, lines 117–127

When `sync()` fails (non-session-expired, non-already-in-progress error), `armTimer` is not re-armed. The schedule effectively dies until the user manually interacts with the picker. This may be intentional (don't retry a failing sync) but warrants a comment.

### L2: `SyncInterval.monthly` Is 28 Days, Not Calendar Month

**File:** `KindleSync/App/SyncManager.swift`, line 24

`4 * 7 * 24 * 3600` = 28 days. Intentional per spec. Informational only.

### L3: DateFormatter Allocated on Every Render in MenuBarContentView

**File:** `KindleSync/UI/MenuBarContentView.swift`, lines 134–146

Both helpers allocate new `DateFormatter` instances on every call. Consider `static let` formatters. Minor for a menu bar app.

### L4: Cover Image MIME Type Hardcoded to `image/jpeg`

**File:** `KindleSync/Sync/KindleSyncEngine.swift`, line 9

Amazon Kindle covers are consistently JPEG. This is safe in practice but fragile if that changes.

### L5: No Logging for Schedule Lifecycle Events

`armTimer`, `setSchedule`, and restore-on-init produce no console output. The sync engine has good logging. Consider `print("[KindleSync] Schedule: next fire at \(date)")`.

### L6: `schemaVersion` Jumps 0 → 2

**File:** `KindleSync/Sync/SyncStateModels.swift`, line 7

Comment says "0 = pre-v1.1; 2 = migrated" — version 1 is never used. Fine, but worth a brief comment explaining the skip.

---

## Requirements Conformance

| REQ | Status | Notes |
|-----|--------|-------|
| REQ-001 | ✅ PASS | `Picker(.radioGroup)` with Weekly/Bi-weekly/Monthly/Off |
| REQ-002 | ✅ PASS | `notifyScheduleSet` fires with next date |
| REQ-003 | ✅ PASS | `notifyScheduleCancelled` fires on disable |
| REQ-004 | ✅ PASS | `notify: false` passed on interval-to-interval change |
| REQ-005 | ✅ PASS | Alert triggers on nil→non-nil with no prior sync |
| REQ-006 | ✅ PASS | "Next: ..." text shown when `nextScheduledSync` non-nil |
| REQ-007 | ✅ PASS | UserDefaults persists interval + nextFire; restored in `init()` |
| REQ-008 | ✅ PASS | `sync()` success branch re-arms timer from `Date()` |
| REQ-009 | ⚠️ PARTIAL | `max(0, ...)` gives delay=0; functionally fires but timing risky during init (see H1) |
| REQ-010 | ✅ PASS | `fetchCoverImageBase64` downloads and returns data URI |
| REQ-011 | ✅ PASS | JS extracts `productUrl`, strips size modifier regex |
| REQ-012 | ✅ PASS | `<img>` tag inserted after header, before `<hr>` |
| REQ-013 | ✅ PASS | Migration loop rewrites all non-current-pass books |
| REQ-014 | ✅ PASS | Normal write loop downloads cover before `buildHTML` |
| REQ-015 | ✅ PASS | Books with new highlights get full rewrite including cover |
| REQ-016 | ✅ PASS | `coverBase64` nil → no `<img>` tag, no placeholder |

---

## Strengths

1. **Clean architecture separation** — scheduling in UserDefaults, sync data in SyncStateStore
2. **Three-state `coverImageURL`** — `nil/""/"https://..."` well-documented and correctly implemented
3. **REQ-004 silent interval switching** — `notify: Bool = true` + `previousInterval` tracking is clean
4. **Migration robustness** — skips `addedByASIN` and `failedASINs`, sets `schemaVersion = 2` after best-effort pass
5. **Actor isolation** — `KindleSyncEngine` actor with `isSyncing` guard; no data races
6. **Backward-compatible Codable** — both new fields decode correctly from pre-v1.1 JSON
7. **`[weak self]` in timer closures** — no retain cycles

---

## Prioritized Action Plan

1. **H1** — Replace `Timer.scheduledTimer` with `Task.sleep` in `SyncManager.armTimer()` to fix past-due relaunch behavior
2. **M1** — Persist `lastSyncDate` to UserDefaults so schedule math is correct after relaunch
3. **M2** — Skip migration `upsert` when no cover URL exists (optimization, not a bug)
4. **L1** — Document that schedule is not re-armed on sync failure (comment in code)
