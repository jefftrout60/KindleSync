import Foundation

actor KindleSyncEngine {
    private var isSyncing = false

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
        let (updatedState, addedByASIN) = SyncStateStore.merge(
            existing: existing,
            newBooks: allBooks,
            newHighlightsByASIN: highlightsByASIN
        )

        // 4. Write Notes for books with new highlights
        let totalAdded = addedByASIN.values.reduce(0) { $0 + $1.count }
        print("[KindleSync] New highlights to write: \(totalAdded) across \(addedByASIN.count) books")
        var totalNew = 0
        var notesFailureCount = 0
        for (asin, newHighlights) in addedByASIN where !newHighlights.isEmpty {
            guard let storedBook = updatedState.books[asin] else { continue }
            let html = NoteFormatter.buildHTML(book: storedBook)
            let title = NoteFormatter.noteTitle(for: storedBook)
            do {
                try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html)
                totalNew += newHighlights.count
            } catch {
                notesFailureCount += 1
                print("[KindleSync] Notes write failed for '\(title)': \(error.localizedDescription)")
            }
        }

        // 5. Persist updated state (includes books that succeeded + those that failed Notes write)
        // State is saved regardless — failed Notes writes will get re-attempted on next full rebuild
        try SyncStateStore.save(updatedState)

        // Surface aggregate Notes failure after state is saved
        if notesFailureCount > 0 {
            throw SyncError.notesError("\(notesFailureCount) book(s) failed to write to Apple Notes.")
        }

        return SyncResult(
            booksProcessed: allBooks.count,
            newHighlightsCount: totalNew,
            completedAt: Date()
        )
    }
}
