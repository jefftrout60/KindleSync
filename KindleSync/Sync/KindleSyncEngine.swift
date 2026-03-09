import Foundation

actor KindleSyncEngine {
    private var isSyncing = false

    // Downloads the cover image to a stable temp path (ks-cover-{asin}.jpg) and returns the URL.
    // osascript (which runs this app's AppleScript) is unsandboxed and can read files from the
    // temp directory. It passes raw image bytes via Apple Events to Notes — Notes never touches
    // the filesystem directly. The temp file persists within a session; OS cleans up on logout.
    private func fetchCoverImage(asin: String, url: String) async -> URL? {
        guard !url.isEmpty, let imageURL = URL(string: url) else { return nil }
        let coverFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ks-cover-\(asin)")
            .appendingPathExtension("jpg")
        if FileManager.default.fileExists(atPath: coverFile.path) {
            return coverFile  // cached for this session
        }
        guard let (data, _) = try? await URLSession.shared.data(from: imageURL) else { return nil }
        guard (try? data.write(to: coverFile)) != nil else { return nil }
        return coverFile
    }

    func sync(fetcher: KindleWebFetcher) async throws -> SyncResult {
        guard !isSyncing else { throw SyncError.alreadyInProgress }
        isSyncing = true
        defer { isSyncing = false }

        // 1. Check Notes permission
        let hasPermission = await AppleNotesWriter.ensureNotesPermission()
        guard hasPermission else {
            throw SyncError.permissionDenied("Apple Notes automation is not authorized.")
        }

        // 2. Fetch all books and highlights via WKWebView JS injection
        let (fetchedBooks, highlightsByASIN) = try await fetcher.fetchAll()
        let rawTotal = highlightsByASIN.values.reduce(0) { $0 + $1.count }
        print("[KindleSync] Raw fetch: \(fetchedBooks.count) books, \(rawTotal) highlights")

        // Skip books without a title — these are typically personal documents or PDFs
        let allBooks = fetchedBooks.filter { !$0.title.isEmpty && !$0.asin.isEmpty }
        let skipped = fetchedBooks.count - allBooks.count
        if skipped > 0 {
            print("[KindleSync] Skipped \(skipped) book(s) with no title or ASIN")
        }

        // 3. Load existing state, diff, merge
        let existing = try SyncStateStore.load()

        // Plausibility guard: if we previously synced N books but the fetch now
        // returns zero, Amazon likely changed their DOM or returned an auth/error
        // page instead of book data. Treat this as a failure rather than silently
        // treating it as "no highlights" and potentially overwriting good state.
        if !existing.books.isEmpty && allBooks.isEmpty {
            throw SyncError.fetchValidationFailed(
                "Fetch returned 0 books but \(existing.books.count) were previously synced. " +
                "Amazon may have changed their page structure.")
        }

        var (updatedState, addedByASIN) = SyncStateStore.merge(
            existing: existing,
            newBooks: allBooks,
            newHighlightsByASIN: highlightsByASIN
        )

        // 4. Write Notes for books with new highlights
        let totalAdded = addedByASIN.values.reduce(0) { $0 + $1.count }
        print("[KindleSync] New highlights to write: \(totalAdded) across \(addedByASIN.count) books")
        var totalNew = 0
        var failedASINs: Set<String> = []
        for (asin, newHighlights) in addedByASIN where !newHighlights.isEmpty {
            guard let storedBook = updatedState.books[asin] else { continue }
            var coverFile: URL? = nil
            if let urlString = storedBook.coverImageURL, !urlString.isEmpty {
                coverFile = await fetchCoverImage(asin: asin, url: urlString)
            }
            let html = NoteFormatter.buildHTML(book: storedBook)
            let title = NoteFormatter.noteTitle(for: storedBook)
            do {
                try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html, coverImagePath: coverFile)
                totalNew += newHighlights.count
            } catch {
                failedASINs.insert(asin)
                print("[KindleSync] Notes write failed for '\(title)': \(error.localizedDescription)")
            }
        }

        // 5. Revert failed books to pre-merge state so their highlights are retried next sync.
        // Without this, merge() would see them as already stored and never include them in
        // addedByASIN again — highlights would be silently lost.
        for asin in failedASINs {
            updatedState.books[asin] = existing.books[asin] // nil for new books = removed from state
        }

        // 5b. Migration pass: rewrite notes with cover images (runs once per schema bump).
        // Schema 2: initial cover image pass (used broken file:// in <img> tag — retired).
        // Schema 3: make new attachment attempt with wrong syntax (file ref as property — retired).
        // Schema 4: HTTPS img src — Notes shows placeholder, never loads (retired).
        // Schema 5: make new attachment with data — hangs (full JPEG too large for Apple Events).
        // Schema 6: same with logging exposed — confirmed hang.
        // Schema 7: resize to 80px thumbnail via sips before passing data (binary data — error -1700).
        // Schema 8: pass POSIX file ref instead of binary data — Notes reads /tmp directly.
        // Schema 9: trailing <p>&nbsp;</p> in HTML so cover attachment doesn't overlap last highlight.
        // Schema 10: pass full-size cover via POSIX file ref directly — no sips thumbnail needed.
        // Schema 11: clear stale attachments before adding cover; 3× trailing &nbsp; to prevent overlap.
        // Schema 12: attach cover at beginning of note instead of end — better UX, no overlap.
        // Schema 13: revert to end; use 5× <br> padding (Notes collapses empty <p> tags).
        // Schema 14: embed cover as data URI in HTML body — Notes renders it as a File icon, not an image (retired).
        // Schema 15: revert to schema 13 POSIX file ref approach; data URI strategy abandoned.
        // Schema 16: scope note search to Kindle Highlights folder; delete-on-error to prevent ghost notes.
        // Schema 17: replace "whose name is" filter with repeat loop — the whose clause treats ":" as an
        //             HFS path separator in object specifiers, silently failing to match titles with colons.
        // Schema 18: fix note title mismatch. Apple Notes derives a note's `name` from the first line of
        //             the HTML body (<h2> = book.title), ignoring the explicitly-set name property. Prior
        //             noteTitle() returned "book.title by book.author" which never matched the stored name,
        //             causing every migration run to create a duplicate instead of updating. Fixed by making
        //             noteTitle() return book.title only. Clear-and-recreate to eliminate accumulated dupes.
        // Schema 19: stop setting `name` in `make new note` — let Notes derive it from the <h2> body content,
        //             matching the behaviour of `set body` updates so new and updated notes look identical.
        if existing.schemaVersion < 19 {
            print("[KindleSync] Running migration (schema → 19): clearing duplicates and rewriting all notes…")
            do {
                try await AppleNotesWriter.clearKindleHighlightsFolder()
            } catch {
                print("[KindleSync] Warning: folder clear failed: \(error.localizedDescription)")
            }
            var migrationCount = 0
            for (asin, storedBook) in updatedState.books
            where !failedASINs.contains(asin) {
                // Skip books with no highlights — nothing to write
                guard !storedBook.highlights.isEmpty else { continue }
                var coverFile: URL? = nil
                if let urlString = storedBook.coverImageURL, !urlString.isEmpty {
                    coverFile = await fetchCoverImage(asin: asin, url: urlString)
                }
                let html = NoteFormatter.buildHTML(book: storedBook)
                let title = NoteFormatter.noteTitle(for: storedBook)
                do {
                    try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html, coverImagePath: coverFile)
                    migrationCount += 1
                } catch {
                    print("[KindleSync] Migration write failed for '\(title)': \(error.localizedDescription)")
                }
            }
            updatedState.schemaVersion = 19
            print("[KindleSync] Migration complete (\(migrationCount) notes)")
        }

        try SyncStateStore.save(updatedState)

        // Surface aggregate Notes failure after state is saved
        if !failedASINs.isEmpty {
            throw SyncError.notesError("\(failedASINs.count) book(s) failed to write to Apple Notes.")
        }

        return SyncResult(
            booksProcessed: allBooks.count,
            newHighlightsCount: totalNew,
            completedAt: Date()
        )
    }
}
