import Foundation

final class SyncStateStore {
    // MARK: - File Location

    private static var storeURL: URL {
        get throws {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dir = appSupport.appendingPathComponent("Kindle Sync", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("sync_state.json")
        }
    }

    // MARK: - Load

    static func load() throws -> SyncState {
        let url = try storeURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SyncState() // First run — empty state, not an error
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SyncState.self, from: data)
    }

    // MARK: - Save

    static func save(_ state: SyncState) throws {
        let url = try storeURL
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomicWrite)
    }

    // MARK: - Merge

    /// Diffs fetched highlights against stored state.
    /// Returns the fully merged state AND a map of only newly added highlights per ASIN.
    static func merge(
        existing: SyncState,
        newBooks: [KindleBook],
        newHighlightsByASIN: [String: [KindleHighlight]]
    ) -> (updated: SyncState, addedByASIN: [String: [StoredHighlight]]) {
        var updatedState = existing
        var addedByASIN: [String: [StoredHighlight]] = [:]

        for book in newBooks {
            let asin = book.asin
            let fetchedHighlights = newHighlightsByASIN[asin] ?? []

            // Get existing stored highlight IDs for this book
            let existingIDs = updatedState.books[asin]?.highlightIds ?? []

            // Find highlights not yet stored
            let newHighlights = fetchedHighlights.filter { !existingIDs.contains($0.highlightId) }
            let storedNew = newHighlights.map { h -> StoredHighlight in
                StoredHighlight(
                    id: h.highlightId,
                    text: h.highlight,
                    note: h.note,
                    location: h.locationValue.isEmpty ? "Location \(h.startPosition)" : h.locationValue,
                    startPosition: h.startPosition,
                    timestamp: h.timestamp,
                    color: h.color
                )
            }

            if var storedBook = updatedState.books[asin] {
                // Book already exists — append new highlights
                storedBook.highlights.append(contentsOf: storedNew)
                storedBook.title = book.title   // update in case title changed
                storedBook.author = book.authors
                updatedState.books[asin] = storedBook
            } else {
                // New book — store all fetched highlights
                let allStored = fetchedHighlights.map { h -> StoredHighlight in
                    StoredHighlight(
                        id: h.highlightId,
                        text: h.highlight,
                        note: h.note,
                        location: h.locationValue.isEmpty ? "Location \(h.startPosition)" : h.locationValue,
                        startPosition: h.startPosition,
                        timestamp: h.timestamp,
                        color: h.color
                    )
                }
                updatedState.books[asin] = StoredBook(
                    asin: asin,
                    title: book.title,
                    author: book.authors,
                    highlights: allStored
                )
                addedByASIN[asin] = allStored
                continue
            }

            if !storedNew.isEmpty {
                addedByASIN[asin] = storedNew
            }
        }

        return (updatedState, addedByASIN)
    }
}
