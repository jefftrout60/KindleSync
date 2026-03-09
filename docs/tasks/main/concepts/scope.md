# Scope: KindleSync v1.1 — Scheduling & Cover Images

*Created: 2026-03-07*

---

## The Problem

KindleSync currently requires manual triggers for every sync, and Apple Notes entries lack visual richness. Two friction points:

1. **Sync scheduling**: Users who want regular syncs must remember to trigger them manually. A set-it-and-forget-it interval removes that burden entirely.

2. **Cover images**: Notes today are text-only. Amazon's Kindle library shows cover art for most books — including it in notes makes them visually recognizable and sets up a future highlights-email feature where images add real value.

---

## Target Users

- **Primary**: Existing KindleSync users who want passive, hands-off syncing
- **Primary**: v1 upgraders who want cover images added to their existing notes without deleting and re-syncing everything

---

## Success Criteria

- User can set a sync schedule in the popover and never think about syncing again
- Next scheduled sync date/time is always visible in the popover when a schedule is active
- Cancelling a schedule is confirmed immediately with a toast
- All notes — new, updated, and existing — include the book cover image from Amazon after upgrading to v1.1
- Migration is seamless: no manual note deletion or re-sync required

---

## User Experience

### Flow 1: Setting a schedule with no prior sync
1. User opens popover — sees schedule picker (Weekly / Bi-weekly / Monthly radio buttons), none selected
2. Selects "Weekly"
3. Alert prompt: "No sync has been run yet. Perform first sync now?"
   - **Yes** → sync runs immediately; schedule timer starts from completion
   - **No** → schedule starts from current time (first sync fires in 1/2/4 weeks)
4. Toast: *"Weekly sync enabled. Next sync: Saturday, Mar 14 at 2:14 PM"*
5. Popover status area shows next scheduled sync date/time

### Flow 2: Setting a schedule when a prior sync exists
1. User selects a radio button
2. Toast: *"Weekly sync enabled. Next sync: [calculated from last sync time]"*
3. Next sync time appears in popover

### Flow 3: Cancelling a schedule
1. User deselects the active radio button
2. Toast: *"Scheduled sync cancelled"*
3. Next sync time disappears from popover
4. *(Switching from Weekly → Monthly updates the schedule silently — no cancel toast)*

### Flow 4: Manual sync with active schedule
1. User hits "Sync Now"
2. Sync runs; schedule timer resets from completion
3. Next sync time in popover updates accordingly

### Flow 5: Cover image in a note
```
KindleSync: Atomic Habits by James Clear    ← title line (unchanged)

[Cover image]                               ← inserted here (linked from Amazon)

Highlight 1...
Highlight 2...
```
- If no image is available for a book → note format is identical to current (no gap, no placeholder)

---

## Scope Boundaries

### ✅ IN

**Scheduling**
- Radio picker: Weekly / Bi-weekly / Monthly — placed below "Sign Out" in the main popover
- Toast on schedule set; toast on schedule cancel
- No toast when switching intervals (e.g., Weekly → Monthly just updates silently)
- "First sync now?" prompt when schedule is selected with no prior sync history
- Next scheduled sync date/time displayed in popover status area when active
- Schedule persists across app quit and relaunch
- Manual sync resets the schedule timer

**Cover Images**
- Amazon cover image **downloaded during sync and embedded as base64** in the note HTML — Apple Notes blocks external `<img src="url">` loading (confirmed via testing)
- Image URL captured from Kindle library API response (not constructed from ASIN)
- Image downloaded at sync time, converted to base64 `data:image/jpeg;base64,...`, embedded in `<img>` tag
- Base64 data is **not persisted** in `sync_state.json` (would bloat the file) — re-downloaded on each note write
- `coverImageURL` (the source URL) stored in `StoredBook` to know which books have images and enable migration
- Inserted between title line and first highlight in the note HTML
- **Retroactive migration (Option C)**: On first launch of v1.1, all existing notes are rewritten to include cover images where available
- All future notes (new or updated with new highlights) always include cover image
- No cover available (or download fails) → note unchanged, no placeholder

### ❌ OUT

- Separate settings panel or nested popover
- Scheduling at a specific time of day (fires relative to last sync, not clock-based)
- Custom interval input
- Persisting base64 image data in sync state (re-downloaded each note write instead)
- Placeholder image for missing covers
- The future highlights-email feature (explicitly deferred)

### ⚠️ Maybe / Future

- Weekly highlights email (random 5 highlights from across all books)
- Time-of-day preference for scheduled syncs
- Sub-weekly intervals (daily, etc.)
- "Refresh all covers" button for manual re-migration

---

## Constraints

- macOS only
- App must be running for scheduled syncs to fire — no background daemon
- Amazon cover image URLs are linked, not cached — if Amazon's image CDN URL pattern changes, images in old notes will break silently
- Apple Notes HTML support for external `<img>` tags needs verification during planning (potential risk)

---

## Integration

**Files touched:**

| File | Change |
|------|--------|
| `KindleSync/UI/MenuBarContentView.swift` | Add schedule picker UI + next sync display |
| `KindleSync/App/SyncManager.swift` | Scheduling logic, timer management, reset on manual sync |
| `KindleSync/Notes/NoteFormatter.swift` | Include cover image `<img>` tag in HTML output |
| `KindleSync/Sync/KindleWebFetcher.swift` | Capture cover image URL from JS scrape |
| `KindleSync/Sync/SyncStateStore.swift` | Persist selected schedule + migration flag for v1.1 |

**Likely unchanged:** `CookieKeychainStore.swift`, `AppleNotesWriter.swift`, `KindleSyncEngine.swift`

---

## Key Decisions

1. **Cover image embedding (not linking)**: Images downloaded at sync time and embedded as base64. Rationale: Apple Notes blocks external `<img src="url">` loading — confirmed via testing on 2026-03-07. Linking is not viable. Base64 embedding is the only approach that works. Notes will be larger but images are durable (not dependent on CDN availability).

2. **Retroactive migration (Option C)**: All existing notes rewritten on first v1.1 launch. Rationale: Heavy readers who finished books and stopped highlighting would never get images under Option B. Required for the future email feature to look good across all books.

3. **Schedule picker in main popover**: Below "Sign Out." Rationale: Avoids nested-popover UX complexity; 3 radio buttons require minimal vertical space.

4. **Schedule fires relative to last sync**: Not at a fixed time of day. Rationale: Simpler; matches the user's mental model of "once a week from when I last synced."

5. **No toast when switching intervals**: Switching Weekly → Monthly is clearly intentional; a toast would be noise. Cancel toast is reserved for the explicit deselect/off action.

---

## Risks

| Risk | Severity | Notes |
|------|----------|-------|
| Apple Notes strips external `<img>` src URLs | ~~High~~ | **Resolved**: Confirmed via testing. Embedding as base64 is required. |
| Amazon image URL pattern changes in future | Low | Base64 images are embedded at sync time — already baked in, no future breakage |
| Migration pass rewrites many notes | Low | Could be slow for users with 100+ books; consider progress indication |
| App not running = missed scheduled sync | Low | Expected behavior for a menu bar app; document clearly |

---

## Next Steps

Complexity: **Medium** (two independent features, 3–5 files each)

Recommended: `/spectre:plan`
