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
        if existing.schemaVersion < 13 {
            print("[KindleSync] Running cover image migration (schema → 13)…")
            var migrationCount = 0
            for (asin, storedBook) in updatedState.books
            where addedByASIN[asin] == nil && !failedASINs.contains(asin) {
                // Skip books with no highlights or no cover URL — nothing to write
                guard !storedBook.highlights.isEmpty,
                      let urlString = storedBook.coverImageURL, !urlString.isEmpty else { continue }
                let coverFile = await fetchCoverImage(asin: asin, url: urlString)
                let html = NoteFormatter.buildHTML(book: storedBook)
                let title = NoteFormatter.noteTitle(for: storedBook)
                do {
                    try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html, coverImagePath: coverFile)
                    migrationCount += 1
                } catch {
                    print("[KindleSync] Migration write failed for '\(title)': \(error.localizedDescription)")
                }
            }
            updatedState.schemaVersion = 13
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
