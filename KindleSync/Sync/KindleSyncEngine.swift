import Foundation

actor KindleSyncEngine {
    private var isSyncing = false

    func sync(cookies: [HTTPCookie]) async throws -> SyncResult {
        guard !isSyncing else { throw SyncError.alreadyInProgress }
        isSyncing = true
        defer { isSyncing = false }

        // 1. Check Notes permission on first call
        let hasPermission = await AppleNotesWriter.ensureNotesPermission()
        guard hasPermission else {
            throw SyncError.permissionDenied("Apple Notes automation is not authorized.")
        }

        // 2. Fetch all books (paginated)
        var allBooks: [KindleBook] = []
        var bookToken: String? = nil
        repeat {
            let page = try await KindleAPIClient.fetchBooks(cookies: cookies, token: bookToken)
            allBooks.append(contentsOf: page.bookList)
            bookToken = page.paginationToken
        } while bookToken != nil

        // 3. Fetch highlights for each book (paginated, 0.5s delay between books)
        var highlightsByASIN: [String: [KindleHighlight]] = [:]
        for (index, book) in allBooks.enumerated() {
            var bookHighlights: [KindleHighlight] = []
            var hlToken: String? = nil
            repeat {
                let page = try await KindleAPIClient.fetchHighlights(asin: book.asin, cookies: cookies, token: hlToken)
                bookHighlights.append(contentsOf: page.highlightList)
                hlToken = page.paginationToken
            } while hlToken != nil
            highlightsByASIN[book.asin] = bookHighlights

            // Rate limit: 0.5s between books (not between pages)
            if index < allBooks.count - 1 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // 4. Load existing state, diff, merge
        let existing = try SyncStateStore.load()
        let (updatedState, addedByASIN) = SyncStateStore.merge(
            existing: existing,
            newBooks: allBooks,
            newHighlightsByASIN: highlightsByASIN
        )

        // 5. Write Notes for books with new highlights
        var totalNew = 0
        for (asin, newHighlights) in addedByASIN where !newHighlights.isEmpty {
            guard let storedBook = updatedState.books[asin] else { continue }
            let html = NoteFormatter.buildHTML(book: storedBook)
            let title = NoteFormatter.noteTitle(for: storedBook)
            do {
                try await AppleNotesWriter.upsert(noteTitle: title, htmlBody: html)
            } catch {
                throw SyncError.notesError(error.localizedDescription)
            }
            totalNew += newHighlights.count
        }

        // 6. Persist updated state
        try SyncStateStore.save(updatedState)

        return SyncResult(
            booksProcessed: allBooks.count,
            newHighlightsCount: totalNew,
            completedAt: Date()
        )
    }
}
