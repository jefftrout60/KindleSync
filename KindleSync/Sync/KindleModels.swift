import Foundation

// MARK: - Book List Response

struct BookListResponse: Codable {
    let bookList: [KindleBook]
    let paginationToken: String?
}

struct KindleBook: Codable, Identifiable {
    let asin: String
    let title: String
    let authors: String
    let numberOfHighlights: Int?
    let lastAccessedDate: Int64?

    var id: String { asin }
}

// MARK: - Highlight List Response

struct HighlightListResponse: Codable {
    let highlightList: [KindleHighlight]
    let paginationToken: String?
}

struct KindleHighlight: Codable, Identifiable {
    let highlightId: String
    let highlight: String
    let note: String?
    let startPosition: Int
    let endPosition: Int?
    let timestamp: Int64
    let color: String?
    let location: HighlightLocation?

    var id: String { highlightId }
}

struct HighlightLocation: Codable {
    let url: String?
    let value: String   // e.g. "Location 1452"
}
