import XCTest
@testable import KindleSync

// MARK: - NoteFormatterTests

final class NoteFormatterTests: XCTestCase {

    func testBuildHTML_containsTitleAndSortedHighlights() {
        let highlightFirst = StoredHighlight(
            id: "h1",
            text: "First highlight text",
            note: "My note",
            location: "Location 100",
            startPosition: 100,
            timestamp: 1700000000000,
            color: nil
        )
        let highlightSecond = StoredHighlight(
            id: "h2",
            text: "Second highlight text",
            note: nil,
            location: "Location 200",
            startPosition: 200,
            timestamp: 1700000001000,
            color: nil
        )
        // Pass highlights in reverse order to verify sorting
        let book = StoredBook(
            asin: "B001",
            title: "Test Book",
            author: "Test Author",
            highlights: [highlightSecond, highlightFirst]
        )

        let html = NoteFormatter.buildHTML(book: book)

        XCTAssertTrue(html.contains("<h2>Test Book</h2>"), "Title should appear in h2 tag")
        XCTAssertTrue(html.contains("<p>Test Author</p>"), "Author should appear in p tag")
        XCTAssertTrue(html.contains("Jeff's Note:"), "Note label should appear when note is non-nil")

        // Verify sort order by location string: "Location 100" must appear before "Location 200"
        let pos100 = html.range(of: "Location 100")
        let pos200 = html.range(of: "Location 200")
        XCTAssertNotNil(pos100, "Location 100 should be present")
        XCTAssertNotNil(pos200, "Location 200 should be present")
        if let r100 = pos100, let r200 = pos200 {
            XCTAssertLessThan(r100.lowerBound, r200.lowerBound, "Lower location number should appear first (sorted by locationNumber(), not startPosition)")
        }
    }

    func testBuildHTML_omitsNoteLineWhenNoteIsNil() {
        let highlight = StoredHighlight(
            id: "h1",
            text: "Some text",
            note: nil,
            location: "Location 50",
            startPosition: 50,
            timestamp: 1700000000000,
            color: nil
        )
        let book = StoredBook(
            asin: "B002",
            title: "Another Book",
            author: "Another Author",
            highlights: [highlight]
        )

        let html = NoteFormatter.buildHTML(book: book)

        XCTAssertFalse(html.contains("Jeff's Note:"), "Note label must not appear when note is nil")
    }
}

// MARK: - SyncStateStoreTests

final class SyncStateStoreTests: XCTestCase {

    private let testASIN = "B001TEST"

    private func makeKindleBook() -> KindleBook {
        KindleBook(asin: testASIN, title: "Merge Test Book", authors: "Merge Author")
    }

    private func makeKindleHighlight(id: String = "highlight-1") -> KindleHighlight {
        KindleHighlight(
            highlightId: id,
            highlight: "Some highlighted text",
            note: nil,
            startPosition: 42,
            timestamp: 1700000000000,
            color: nil,
            locationValue: "Location 42"
        )
    }

    func testMerge_newBook_returnsAllHighlightsAsAdded() {
        let book = makeKindleBook()
        let highlight = makeKindleHighlight()

        let result = SyncStateStore.merge(
            existing: SyncState(),
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlight]]
        )

        XCTAssertNotNil(result.addedByASIN[testASIN], "New book highlights should appear in addedByASIN")
        XCTAssertEqual(result.addedByASIN[testASIN]?.count, 1, "One new highlight should be returned")
        XCTAssertEqual(result.addedByASIN[testASIN]?.first?.id, "highlight-1")

        XCTAssertNotNil(result.updated.books[testASIN], "Book should be present in updated state")
        XCTAssertEqual(result.updated.books[testASIN]?.title, "Merge Test Book")
    }

    func testMerge_existingHighlight_returnsEmptyAddedMap() {
        let book = makeKindleBook()
        let highlight = makeKindleHighlight()

        // First merge: book is new, highlight gets added
        let firstResult = SyncStateStore.merge(
            existing: SyncState(),
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlight]]
        )

        // Second merge with the same highlight against the already-merged state
        let secondResult = SyncStateStore.merge(
            existing: firstResult.updated,
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlight]]
        )

        XCTAssertNil(secondResult.addedByASIN[testASIN], "Duplicate highlight should not appear as added")
        XCTAssertEqual(secondResult.updated.books[testASIN]?.highlights.count, 1, "Highlight count should remain 1 after deduplication")
    }
}

// MARK: - CookieKeychainStoreTests

final class CookieKeychainStoreTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CookieKeychainStore.delete()
    }

    override func tearDown() {
        CookieKeychainStore.delete()
        super.tearDown()
    }

    func testSaveAndLoad_preservesCookieFields() throws {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name:   "session-token",
            .value:  "test-value-abc123",
            .domain: ".amazon.com",
            .path:   "/"
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            XCTFail("Failed to create test cookie")
            return
        }

        try CookieKeychainStore.save([cookie])
        let loaded = try CookieKeychainStore.load()

        XCTAssertEqual(loaded.count, 1, "Should load exactly one cookie")
        XCTAssertEqual(loaded.first?.name, "session-token")
        XCTAssertEqual(loaded.first?.value, "test-value-abc123")
        XCTAssertEqual(loaded.first?.domain, ".amazon.com")
    }

    func testLoadAfterDelete_throwsNotFound() {
        // setUp already called delete(); just confirm load throws
        XCTAssertThrowsError(try CookieKeychainStore.load()) { error in
            guard case KeychainError.notFound = error else {
                XCTFail("Expected KeychainError.notFound, got \(error)")
                return
            }
        }
    }
}

// MARK: - SyncStateStorePersistenceTests

final class SyncStateStorePersistenceTests: XCTestCase {

    private var stateFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Kindle Sync/sync_state.json")
    }

    override func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateFileURL)
        super.tearDown()
    }

    func testLoad_absentFile_returnsEmptySyncState() throws {
        // File deleted in setUp — load() must return empty state without throwing
        let state = try SyncStateStore.load()
        XCTAssertTrue(state.books.isEmpty, "books should be empty on first run (no file present)")
    }

    func testSaveAndLoad_roundTrip_preservesHighlightFields() throws {
        let highlight = StoredHighlight(
            id: "h-roundtrip",
            text: "Round trip text",
            note: "Personal note",
            location: "Location 123",
            startPosition: 123,
            timestamp: 1700000000000,
            color: "yellow"
        )
        let book = StoredBook(
            asin: "B999ROUND",
            title: "Round Trip Book",
            author: "Round Trip Author",
            highlights: [highlight]
        )
        var state = SyncState()
        state.books["B999ROUND"] = book

        try SyncStateStore.save(state)
        let loaded = try SyncStateStore.load()

        let loadedBook = try XCTUnwrap(loaded.books["B999ROUND"])
        XCTAssertEqual(loadedBook.asin, "B999ROUND")
        XCTAssertEqual(loadedBook.title, "Round Trip Book")
        XCTAssertEqual(loadedBook.author, "Round Trip Author")

        let loadedHighlight = try XCTUnwrap(loadedBook.highlights.first)
        XCTAssertEqual(loadedHighlight.id, "h-roundtrip")
        XCTAssertEqual(loadedHighlight.text, "Round trip text")
        XCTAssertEqual(loadedHighlight.note, "Personal note")
        XCTAssertEqual(loadedHighlight.location, "Location 123")
        XCTAssertEqual(loadedHighlight.startPosition, 123)
        XCTAssertEqual(loadedHighlight.timestamp, 1700000000000)
        XCTAssertEqual(loadedHighlight.color, "yellow")
    }
}
