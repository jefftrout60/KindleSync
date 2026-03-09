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

    func testNoteTitle_withBookTitleAndAuthor_returnsOnlyTitle() {
        let book = StoredBook(
            asin: "B003",
            title: "The Great Gatsby",
            author: "F. Scott Fitzgerald",
            highlights: []
        )

        let title = NoteFormatter.noteTitle(for: book)

        XCTAssertEqual(title, "The Great Gatsby", "noteTitle should return exactly book.title")
        XCTAssertFalse(title.contains(" by "), "noteTitle must not contain ' by '")
        XCTAssertFalse(title.contains(book.author), "noteTitle must not contain the author name")
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

    func testMerge_existingBookWithNewHighlight_appendsAndReturnsInAdded() {
        let book = makeKindleBook()
        let highlightH1 = makeKindleHighlight(id: "h1")
        let highlightH2 = makeKindleHighlight(id: "h2")

        // First merge: new book with one highlight (h1)
        let firstResult = SyncStateStore.merge(
            existing: SyncState(),
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlightH1]]
        )

        // Second merge: same book, now with both h1 (existing) and h2 (new)
        let secondResult = SyncStateStore.merge(
            existing: firstResult.updated,
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlightH1, highlightH2]]
        )

        XCTAssertEqual(secondResult.addedByASIN[testASIN]?.count, 1, "Only the new highlight (h2) should appear in addedByASIN")
        XCTAssertEqual(secondResult.addedByASIN[testASIN]?.first?.id, "h2", "The newly added highlight id should be h2")
        XCTAssertEqual(secondResult.updated.books[testASIN]?.highlights.count, 2, "Both h1 and h2 should be stored after second merge")
    }

    func testMerge_emptyLocationValue_fallsBackToLocationWithStartPosition() {
        let book = makeKindleBook()
        let highlight = KindleHighlight(
            highlightId: "loc-fallback",
            highlight: "Some text",
            note: nil,
            startPosition: 77,
            timestamp: 1700000000000,
            color: nil,
            locationValue: ""
        )

        let result = SyncStateStore.merge(
            existing: SyncState(),
            newBooks: [book],
            newHighlightsByASIN: [testASIN: [highlight]]
        )

        let storedHighlight = result.updated.books[testASIN]?.highlights.first
        XCTAssertEqual(storedHighlight?.location, "Location 77", "Empty locationValue should fall back to 'Location <startPosition>'")
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

    func testAreCookiesExpired_returnsFalse_whenSessionCookieHasFutureExpiry() {
        let futureDate = Date().addingTimeInterval(7 * 24 * 3600)
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name:    "session-token",
            .value:   "valid-token",
            .domain:  ".amazon.com",
            .path:    "/",
            .expires: futureDate
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            XCTFail("Failed to create test cookie with future expiry")
            return
        }

        let result = CookieKeychainStore.areCookiesExpired([cookie])

        XCTAssertFalse(result, "Cookie with a future expiresDate should not be treated as expired")
    }

    func testAreCookiesExpired_returnsTrue_whenSessionCookieIsExpired() {
        let pastDate = Date().addingTimeInterval(-3600)
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name:    "session-token",
            .value:   "old-token",
            .domain:  ".amazon.com",
            .path:    "/",
            .expires: pastDate
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            XCTFail("Failed to create test cookie with past expiry")
            return
        }

        let result = CookieKeychainStore.areCookiesExpired([cookie])

        XCTAssertTrue(result, "Cookie whose expiresDate is in the past should be treated as expired")
    }

    func testAreCookiesExpired_returnsTrue_whenNoSessionCookiesPresent() {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name:   "ubid-main",
            .value:  "some-value",
            .domain: ".amazon.com",
            .path:   "/"
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            XCTFail("Failed to create non-session test cookie")
            return
        }

        let result = CookieKeychainStore.areCookiesExpired([cookie])

        XCTAssertTrue(result, "No session-token or session-id cookies present should be treated as expired")
    }

    func testAreCookiesExpired_returnsFalse_whenSessionCookieHasNoExpiresDate() {
        // Omit .expires — HTTPCookie will have a nil expiresDate
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name:   "session-id",
            .value:  "persistent-session",
            .domain: ".amazon.com",
            .path:   "/"
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            XCTFail("Failed to create test cookie without expiry")
            return
        }

        let result = CookieKeychainStore.areCookiesExpired([cookie])

        XCTAssertFalse(result, "Session cookie with no expiresDate should not be treated as expired")
    }
}

// MARK: - SyncStateDecodingTests

final class SyncStateDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    func testSyncState_jsonWithSchemaVersion_decodesExplicitValue() throws {
        let jsonWith = """
        {"books":{},"schemaVersion":5}
        """.data(using: .utf8)!

        let state = try decoder.decode(SyncState.self, from: jsonWith)

        XCTAssertEqual(state.schemaVersion, 5, "schemaVersion should decode to the explicit value present in JSON")
    }

    func testSyncState_jsonWithoutSchemaVersion_defaultsToZero() throws {
        // Simulates JSON written by v1.0 before schemaVersion was added
        let jsonWithout = """
        {"books":{}}
        """.data(using: .utf8)!

        let state = try decoder.decode(SyncState.self, from: jsonWithout)

        XCTAssertEqual(state.schemaVersion, 0, "schemaVersion should default to 0 when the key is absent (v1.0 backward compatibility)")
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
