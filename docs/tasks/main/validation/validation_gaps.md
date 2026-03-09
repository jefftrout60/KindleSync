# Validation Gaps: KindleSync v1.1 — Scheduling & Cover Images
*Generated: 2026-03-07*

## Summary
- **Overall Status**: Complete
- **Requirements**: 16 of 16 delivered
- **Gaps Found**: 0 requiring remediation
- **Scope Creep**: 0 items

---

## Gap Remediation Tasks

*None — all requirements delivered.*

---

## Scope Creep Review

*None found.*

---

## Validation Coverage

| Area | Status | Primary File | Key Definition | Render Chain |
|------|--------|-------------|----------------|--------------|
| Scheduling State & Persistence | ✅ | SyncManager.swift | setSchedule():131, armTimer():148, init():60 | UserDefaults persist/restore ✓ |
| Schedule UI & User Flows | ✅ | MenuBarContentView.swift | Picker:52, alert:84, Text("Next:"):77 | JSX ← nextScheduledSync ← armTimer ✓ |
| Cover Image Pipeline | ✅ | KindleSyncEngine.swift | fetchCoverImageBase64():6, write loop:48 | buildHTML ← base64 ← URLSession ✓ |
| Retroactive Migration Pass | ✅ | KindleSyncEngine.swift | migration block:79-101 | schemaVersion < 2 → rewrite → set 2 ✓ |

---

## Requirement-by-Requirement Coverage

| REQ | Description | Status | Evidence |
|-----|-------------|--------|----------|
| REQ-001 | Schedule picker in popover below Sign Out | ✅ | `MenuBarContentView.swift:52` — `Picker(.radioGroup)` after Divider + Log Out |
| REQ-002 | Toast on schedule set with next sync date | ✅ | `SyncManager.swift:145` — `notifyScheduleSet()` gated on `notify: true` |
| REQ-003 | Toast on schedule cancel | ✅ | `SyncManager.swift:139` — `notifyScheduleCancelled()` gated on `notify: true` |
| REQ-004 | No toast when switching intervals | ✅ | `MenuBarContentView.swift:66` — `notify = previousInterval == nil \|\| newValue == nil` |
| REQ-005 | "First sync now?" prompt when no prior sync | ✅ | `MenuBarContentView.swift:68-70` — triggered when `previousInterval == nil && lastSyncDate == nil` |
| REQ-006 | Next sync date/time in popover when active | ✅ | `MenuBarContentView.swift:76-80` — `if let nextSync = syncManager.nextScheduledSync` |
| REQ-007 | Schedule persists across quit/relaunch | ✅ | `SyncManager.swift:69-77` — UserDefaults `syncInterval` + `nextScheduledSync` restored in `init()` |
| REQ-008 | Manual sync resets schedule timer | ✅ | `SyncManager.swift:115-117` — `armTimer(for: Date() + interval.seconds)` in `sync()` success |
| REQ-009 | Past-due schedule on relaunch → immediate sync | ✅ | `SyncManager.swift:152-156` — `max(0, delay)`, `if delay > 0` sleep skipped for past dates |
| REQ-010 | Cover image downloaded and embedded as base64 | ✅ | `KindleSyncEngine.swift:6-10` — `fetchCoverImageBase64` returns `data:image/jpeg;base64,...` |
| REQ-011 | Cover URL from Kindle API productUrl field | ✅ | `KindleWebFetcher.swift:226-228` — JS extracts `b.productUrl` with regex size-modifier strip |
| REQ-012 | Image between title line and first highlight | ✅ | `NoteFormatter.swift:15-17` — `<img>` tag after sync date line, before `<hr>` |
| REQ-013 | Retroactive migration on first v1.1 sync | ✅ | `KindleSyncEngine.swift:79-101` — `schemaVersion < 2` block rewrites all eligible books |
| REQ-014 | New notes always include cover image | ✅ | `KindleSyncEngine.swift:48-56` — all books in `addedByASIN` attempt cover fetch |
| REQ-015 | Notes with new highlights include cover image | ✅ | Same write loop path — existing books with new highlights go through identical cover logic |
| REQ-016 | No cover available → note unchanged, no placeholder | ✅ | `NoteFormatter.swift:15` — `if let imgData = coverImageBase64, !imgData.isEmpty` guard; no else |

---

## Dead Computations Found

*None.*

## Old Code Paths Still Active

*None.*

---

## Notes

**REQ-016 behavioral clarification**: "Note unchanged" means no cover-image element is added when no image is available — it does not mean the note write is skipped when new highlights exist. When a book has new highlights but no cover, the note is still written with the new highlights (per REQ-014/015). The "unchanged" intent only applies to the absence of any placeholder image or gap in the note layout. This is correct behavior.
