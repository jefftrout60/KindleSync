---
name: gotchas-apple-notes-upsert
description: Use when Apple Notes upsert creates duplicate notes, or when debugging AppleScript note lookup across iCloud and On My Mac accounts.
user-invocable: false
---

# Gotcha: Apple Notes Duplicate on Upsert

**Trigger**: apple notes, duplicate notes, upsert, osascript, notes in folder
**Confidence**: high
**Created**: 2026-03-06
**Updated**: 2026-03-06
**Version**: 1

## Symptom

Second sync creates a *new* note instead of updating the existing one. You end up with two notes for the same book in Apple Notes.

## Root Cause

`notes in targetFolder whose name is noteName` scopes the lookup to *one specific folder object*. On Macs with both iCloud Notes and On My Mac accounts, `folder "Kindle Highlights"` may resolve to *either* account's folder depending on which account is "first." The note was created in one account's folder; the search resolves to the other account's folder; it finds nothing and creates a duplicate.

## Solution

Search across *all* notes, not within a folder:

```applescript
-- ✅ Correct: searches all notes regardless of account
set matchingNotes to (every note whose name is noteName)
if (count of matchingNotes) > 0 then
    set body of (item 1 of matchingNotes) to noteContent
else
    make new note at targetFolder with properties {name:noteName, body:noteContent}
end if

-- ❌ Wrong: scopes to one folder, misses notes in other account
set matchingNotes to (notes in targetFolder whose name is noteName)
```

Note: creation still targets `targetFolder` (the "Kindle Highlights" folder) — only the *lookup* needs to be global.

## Prevention

Always use `every note whose name is X` for upsert lookups. Only use folder-scoped queries for *creating* new notes.
