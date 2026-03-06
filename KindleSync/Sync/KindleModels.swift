import Foundation

// MARK: - Book (from /kindle-library/search)

struct KindleBook: Identifiable {
    let asin: String
    let title: String
    let authors: String
    var id: String { asin }
}

// MARK: - Highlight (from HTML scraping of /notebook?asin=...)

struct KindleHighlight: Identifiable {
    let highlightId: String     // deterministic: asin#fnv32a(text+location)
    let highlight: String       // highlight text
    let note: String?           // personal note
    let startPosition: Int      // numeric from location string
    let timestamp: Int64        // epoch ms, or 0 if unknown
    let color: String?          // yellow/blue/pink/orange
    let locationValue: String   // "Location 1234" or "Page 23"
    var id: String { highlightId }
}
