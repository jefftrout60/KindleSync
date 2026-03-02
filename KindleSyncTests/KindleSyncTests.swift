import XCTest
@testable import KindleSync

// MARK: - MockURLProtocol

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

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
        XCTAssertTrue(html.contains("📝"), "Note indicator should appear when note is non-nil")

        // Verify sort order: Location 100 must appear before Location 200
        let pos100 = html.range(of: "Location 100")
        let pos200 = html.range(of: "Location 200")
        XCTAssertNotNil(pos100, "Location 100 should be present")
        XCTAssertNotNil(pos200, "Location 200 should be present")
        if let r100 = pos100, let r200 = pos200 {
            XCTAssertLessThan(r100.lowerBound, r200.lowerBound, "Lower startPosition should appear first")
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

        XCTAssertFalse(html.contains("📝"), "Note indicator must not appear when note is nil")
    }
}

// MARK: - SyncStateStoreTests

final class SyncStateStoreTests: XCTestCase {

    private let testASIN = "B001TEST"

    private func makeKindleBook() -> KindleBook {
        KindleBook(
            asin: testASIN,
            title: "Merge Test Book",
            authors: "Merge Author",
            numberOfHighlights: 1,
            lastAccessedDate: nil
        )
    }

    private func makeKindleHighlight(id: String = "highlight-1") -> KindleHighlight {
        KindleHighlight(
            highlightId: id,
            highlight: "Some highlighted text",
            note: nil,
            startPosition: 42,
            endPosition: nil,
            timestamp: 1700000000000,
            color: nil,
            location: HighlightLocation(url: nil, value: "Location 42")
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

// MARK: - KindleAPIClientTests

final class KindleAPIClientTests: XCTestCase {

    var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    func testFetchBooks_happyPath_decodesResponse() async throws {
        let json = """
        {"bookList":[{"asin":"B001","title":"Test Book","authors":"Test Author","numberOfHighlights":1}],"paginationToken":null}
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let url = request.url ?? URL(string: "https://read.amazon.com")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        let result = try await KindleAPIClient.fetchBooks(cookies: [], token: nil, session: session)

        XCTAssertEqual(result.bookList.count, 1)
        XCTAssertEqual(result.bookList.first?.asin, "B001")
        XCTAssertEqual(result.bookList.first?.title, "Test Book")
        XCTAssertEqual(result.bookList.first?.authors, "Test Author")
    }

    func testFetchBooks_sessionExpired_throwsSessionExpiredError() async throws {
        MockURLProtocol.requestHandler = { _ in
            let signinURL = URL(string: "https://www.amazon.com/ap/signin?openid=foo")!
            let response = HTTPURLResponse(url: signinURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = Data()
            return (response, data)
        }

        do {
            _ = try await KindleAPIClient.fetchBooks(cookies: [], token: nil, session: session)
            XCTFail("Expected SyncError.sessionExpired to be thrown")
        } catch SyncError.sessionExpired {
            // Expected
        } catch {
            XCTFail("Expected SyncError.sessionExpired, got \(error)")
        }
    }
}
