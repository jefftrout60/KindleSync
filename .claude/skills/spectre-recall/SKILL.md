---
name: spectre-recall
description: Use when user wants to search for existing knowledge, recall a specific learning, or discover what knowledge is available.
---

# Recall Knowledge

Search and load relevant knowledge from the project's spectre learnings into your context.

## Registry

# SPECTRE Knowledge Registry
# Format: skill-name|category|triggers|description

feature-kindlesync-architecture|feature|kindlesync, kindle sync, sync pipeline, apple notes, kindlewebfetcher, syncengine, syncmanager, syncstate|Use when working on KindleSync — understanding the sync pipeline, auth flow, data models, or any component of the app.
gotchas-apple-notes-upsert|gotchas|apple notes, duplicate notes, upsert, osascript, notes in folder, notes automation|Use when Apple Notes upsert creates duplicate notes, or when debugging AppleScript note lookup across iCloud and On My Mac accounts.
gotchas-xcode-test-config|gotchas|unit tests, xcode, test bundle, cmd+u, no test bundles, product test greyed out, test host, code signing tests, development team|Use when Xcode unit tests won't run, Product > Test is greyed out, Cmd+U does nothing, or "no test bundles available" error appears.

## How to Use

1. **Scan registry above** — match triggers/description against your current task
2. **Load matching skills**: `Skill({skill-name})`
3. **Apply knowledge** — use it to guide your approach

## Search Commands

- `/recall {query}` — search registry for matches
- `/recall` — show all available knowledge by category

## Workflow

**Single match** → Load automatically via `Skill({skill-name})`

**Multiple matches** → List options, ask user which to load

**No matches** → Suggest `/learn` to capture new knowledge
