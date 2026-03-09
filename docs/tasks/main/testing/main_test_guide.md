# Manual Test Guide — KindleSync v1.1: Scheduling & Cover Images

*Generated: 2026-03-07 | Branch: main*

---

## Testing Overview

**Scope**: Two new features — automatic sync scheduling (Weekly/Bi-weekly/Monthly) and book cover image embedding in Apple Notes, including retroactive migration of existing notes.

**Complexity**: Complex — persistent state, lifecycle behavior, external system integration (Apple Notes), network dependency (Amazon CDN), and a one-time migration pass.

**Environment**: macOS 13+ with Kindle account, books with highlights, existing Apple Notes from v1.0 (for migration testing).

**Prerequisites**:
- KindleSync built and running (Xcode or installed .app)
- Amazon account signed in (or can sign in during test)
- At least 3-5 books with highlights in your Kindle library
- Apple Notes open and accessible (Notes automation permission granted)
- Notification permissions granted for KindleSync
- v1.0 notes already synced to Apple Notes (for migration scenarios)
- Console.app open to monitor `[KindleSync]` log output during complex scenarios

---

## 1. Schedule Picker — Basic Setup (REQ-001, REQ-006)

- [ ] Open the KindleSync popover (click menu bar icon) — verify the schedule picker is visible below the "Log Out" button, separated by a divider
- [ ] Verify the picker shows radio buttons: Off, Weekly, Bi-weekly, Monthly — with "Off" selected by default on a fresh install
- [ ] Verify no "Next sync:" text is visible in the popover when "Off" is selected
- [ ] Select "Weekly" — verify a "Next sync:" line appears below the picker showing a date roughly 7 days from now (or from last sync date)
- [ ] Verify the next sync date/time includes both date and time (e.g., "Mar 14 at 2:14 PM"), not just a date
- [ ] Select "Bi-weekly" — verify the "Next sync:" date updates to ~14 days out
- [ ] Select "Monthly" — verify the "Next sync:" date updates to ~28 days out
- [ ] Select "Off" — verify the "Next sync:" line disappears

---

## 2. Schedule Set Toast (REQ-002)

- [ ] With "Off" selected, select "Weekly" — verify a system notification banner appears: title contains "Kindle Sync scheduled" and body includes "Weekly" and the next sync date
- [ ] Dismiss the notification; select "Off" to clear, then select "Monthly" — verify another toast appears with "Monthly" in the body
- [ ] Verify the next sync date shown in the toast matches the date shown in the popover

---

## 3. Schedule Cancel Toast (REQ-003)

- [ ] With "Weekly" active, select "Off" — verify a system notification banner appears with a cancellation message (e.g., "Kindle Sync schedule cancelled" or similar)
- [ ] Verify no "Next sync:" text remains in the popover after cancellation

---

## 4. Silent Interval Switching — No Toast (REQ-004)

- [ ] Set schedule to "Weekly" (toast appears — expected)
- [ ] While "Weekly" is active, switch directly to "Bi-weekly" — verify NO notification toast appears for this switch
- [ ] Verify the "Next sync:" date in the popover silently updates to reflect the bi-weekly interval
- [ ] Switch from "Bi-weekly" to "Monthly" — verify again no toast appears
- [ ] Switch from "Monthly" back to "Weekly" — verify no toast appears
- [ ] Verify that only switching TO "Off" (cancel) or FROM "Off" (new schedule) fires a notification

---

## 5. First Sync Alert — No Prior Sync History (REQ-005)

*Test requires a fresh install or cleared UserDefaults (no prior sync history).*

- [ ] Ensure there is no prior sync date stored: quit the app, run `defaults delete com.jeff.kindlesync` (or app bundle ID) in Terminal to reset, relaunch
- [ ] Open popover — verify "Off" is selected and no next sync date is shown
- [ ] Select "Weekly" — verify a native macOS alert dialog appears: "No sync has been run yet. Perform first sync now?" (or similar wording) with "Sync Now" and "Later" buttons
- [ ] Click "Later" — verify the alert dismisses, schedule is armed (next sync ~7 days out shown in popover), and no sync starts
- [ ] Select "Off" to cancel, then select "Weekly" again — verify alert appears again (no prior sync still)
- [ ] Click "Sync Now" — verify a sync starts immediately (menu bar icon animates, status updates), and after completion the next sync date advances by 7 days from completion time

---

## 6. First Sync Alert — Skipped When Prior Sync Exists (REQ-005 boundary)

- [ ] After a successful sync has been run (any sync), select "Off" to clear schedule
- [ ] Select "Weekly" again — verify the "First sync now?" alert does NOT appear (prior sync history exists)
- [ ] Verify the schedule arms silently with a toast showing the next sync date
- [ ] Switch between intervals (Bi-weekly, Monthly, Weekly) — verify no first-sync alert in any transition

---

## 7. Schedule Persistence — Quit and Relaunch (REQ-007)

- [ ] Set schedule to "Bi-weekly" — note the exact "Next sync:" date/time shown in the popover
- [ ] Quit KindleSync (right-click menu bar icon → Quit, or Cmd+Q)
- [ ] Relaunch KindleSync
- [ ] Open the popover — verify "Bi-weekly" is still selected (not reset to "Off")
- [ ] Verify the "Next sync:" date matches what was shown before quit (not recalculated from launch time)
- [ ] Repeat with "Monthly" to confirm persistence works for all intervals

---

## 8. Manual Sync Resets Schedule Timer (REQ-008)

- [ ] Set schedule to "Weekly" — note the "Next sync:" date shown (should be ~7 days out)
- [ ] Trigger a manual sync by pressing "Sync Now" in the popover
- [ ] Wait for sync to complete (status returns to idle/success)
- [ ] Open the popover — verify the "Next sync:" date has reset to ~7 days from the completion time of the manual sync, not from the original scheduled time
- [ ] Verify the new next sync date is later than the previous one

---

## 9. Past-Due Schedule Fires Immediately on Relaunch (REQ-009)

*Requires manipulating UserDefaults to simulate a past-due fire date.*

- [ ] Set schedule to "Weekly" via the UI — a `nextScheduledSync` timestamp is written to UserDefaults
- [ ] Quit KindleSync
- [ ] In Terminal, set the next fire date to the past:
  ```
  defaults write com.jeff.kindlesync nextScheduledSync $(date -v-2d +%s)
  ```
  (Replace `com.jeff.kindlesync` with the actual bundle ID if different)
- [ ] Relaunch KindleSync — verify a sync starts immediately on launch (menu bar shows syncing state without any user interaction)
- [ ] Confirm in Console.app that `[KindleSync]` logs show a sync completing
- [ ] After sync, verify the "Next sync:" date in the popover advances to ~7 days from completion (not from the past-due date)

---

## 10. Cover Image — New Note Created with Image (REQ-010, REQ-012, REQ-014)

*Requires a book in your Kindle library with highlights that has NOT been synced yet (or clear sync state to force re-creation).*

- [ ] Identify a book with highlights that either hasn't been synced, or temporarily delete its note from Apple Notes
- [ ] Run a sync ("Sync Now")
- [ ] Open Apple Notes — find the note for that book
- [ ] Verify the note contains a cover image between the header line ("KindleSync: [Title] by [Author]") and the first highlight
- [ ] Verify the image is visible and correctly renders the book cover (not broken/placeholder)
- [ ] Verify highlights appear after the cover image, not before it
- [ ] Verify no gap or empty space exists where an image would be if the book had no cover (see scenario 14)

---

## 11. Cover Image — Existing Note Updated with New Highlights Gets Image (REQ-015)

- [ ] Find a book that has an existing note in Apple Notes from v1.0 (no cover image yet) and add a new highlight to it via the Kindle app/website
- [ ] Run a sync
- [ ] Open the updated note in Apple Notes — verify the cover image is now present between the header and highlights
- [ ] Verify previously synced highlights are still present and in correct order

---

## 12. Cover Image URL Captured from API (REQ-011)

*Verify at the data level — requires Console.app or code inspection.*

- [ ] Run a sync and observe Console.app output for `[KindleSync]` logs
- [ ] Verify no errors relating to cover image fetching appear for books that have visible cover images in the Kindle library
- [ ] Open a successfully synced note in Apple Notes and use Edit menu → "Get Info" or inspect source — the image `src` should begin with `data:image/jpeg;base64,` (not an `https://` URL)
- [ ] Verify the image data is embedded (note file size is notably larger than a plain-text note)

---

## 13. Cover Image — Missing Cover Leaves Note Unchanged (REQ-016)

*Some books (personal documents, older titles) may lack cover images.*

- [ ] Identify a book in your Kindle library that does NOT have a visible cover thumbnail in the Amazon Kindle web reader — or use a personal document (PDF/MOBI sideload)
- [ ] Sync that book
- [ ] Open its Apple Notes entry — verify:
  - No broken image icon appears
  - No blank space or gap between the header and first highlight
  - The note layout is identical to a pre-v1.1 note (header → highlights, no image section at all)
- [ ] Verify the sync completed successfully (no error notification) despite the missing cover

---

## 14. Retroactive Migration — Existing Notes Get Cover Images (REQ-013)

*This is a one-time migration that runs on first sync after upgrading to v1.1. Requires existing v1.0 notes.*

- [ ] Verify you have multiple books already synced to Apple Notes from v1.0 (notes without cover images)
- [ ] If testing in development: ensure `schemaVersion` is not yet set to 2 (fresh build from v1.1 source, first run)
- [ ] Run a sync — observe Console.app for `[KindleSync] Running v1.1 cover image migration…` and `[KindleSync] Migration complete` log messages
- [ ] After sync completes, open Apple Notes — select 3-5 previously synced books
- [ ] Verify each note now contains a cover image between the header and first highlight (for books that have covers)
- [ ] Verify books with no cover available still have no placeholder (note layout unchanged)
- [ ] Run a second sync — verify Console.app does NOT show migration log messages (migration only runs once)
- [ ] Quit and relaunch, run another sync — verify migration does not re-run again

---

## 15. Migration Resilience — Partial Failures Don't Fail Sync (REQ-013 edge)

- [ ] During a migration sync (first v1.1 sync), if Apple Notes is closed or unresponsive, verify:
  - The sync does not throw a fatal error or show a failure notification for the overall sync
  - Individual migration write failures are silently skipped (check Console.app for `[KindleSync] Migration write failed` warnings vs sync-level errors)
- [ ] After resolving Apple Notes access, run another sync — note that migration will NOT re-run (schemaVersion is already 2 from the first attempt), so migration-failed books remain without images until they receive new highlights

---

## 16. Scheduling + Manual Sync Integration

- [ ] Set schedule to "Weekly" with a known next sync date
- [ ] Run a manual sync via "Sync Now"
- [ ] Verify the "Next sync:" date in the popover updates to ~7 days from the manual sync completion time (not the original scheduled time)
- [ ] Verify no duplicate "schedule set" notification fires after the manual sync resets the timer
- [ ] Trigger the scheduled sync by waiting (or manipulating the fire date as in scenario 9) and verify the timer self-resets after the scheduled sync completes

---

## 17. Notification Permission Handling

- [ ] If notification permissions were previously denied for KindleSync, revoke them in System Settings → Notifications
- [ ] Set a schedule — verify the app does not crash when it cannot send a notification
- [ ] Grant notification permissions, set/cancel a schedule — verify banners now appear correctly

---

## Results Documentation

For each failed test step, record:

| Test # | Step | Expected | Actual | Repro Steps |
|--------|------|----------|--------|-------------|
| | | | | |

**Pass criteria**: All steps marked ✅ with no unexpected behavior.

**Known acceptable gaps**:
- Cover images require network access to Amazon's CDN — tests in offline environments will result in notes without images (expected behavior per REQ-016)
- Migration only runs once; testing it requires a fresh state or manual `schemaVersion` reset in `sync_state.json`
- The "Monthly" interval is 28 days (4 weeks), not a calendar month — next sync date should reflect this
- App must be running for scheduled syncs to fire — a scheduled sync will not run if the app is quit

---

*Estimated test time: 45-60 minutes (all scenarios) | Core scenarios (1-8, 10, 13): ~30 minutes*
