import Foundation

// MARK: - Sync State (top-level persisted structure)

struct SyncState: Codable {
    var books: [String: StoredBook]  // keyed by ASIN
    var schemaVersion: Int           // 0 = pre-v1.1 (needs migration)

    init() {
        self.books = [:]
        self.schemaVersion = 0
    }

    // Custom decoder so schemaVersion defaults to 0 when the key is absent
    // (e.g. JSON written by v1.0 before the field existed). Swift's synthesised
    // init(from:) treats missing required keys as a hard error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.books = try c.decode([String: StoredBook].self, forKey: .books)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    }
}

// MARK: - Stored Book

struct StoredBook: Codable {
    let asin: String
    var title: String
    var author: String
    var highlights: [StoredHighlight]
    var coverImageURL: String?   // nil = not yet fetched, "" = fetched but no image, "https://..." = valid URL

    var highlightIds: Set<String> {
        Set(highlights.map(\.id))
    }
}

// MARK: - Stored Highlight (mirrors KindleHighlight fields needed for rendering)

struct StoredHighlight: Codable, Identifiable {
    let id: String          // = KindleHighlight.highlightId
    let text: String        // = KindleHighlight.highlight
    let note: String?       // = KindleHighlight.note
    let location: String    // = KindleHighlight.locationValue (or "Location \(startPosition)" if empty)
    let startPosition: Int  // for sorting
    let timestamp: Int64    // epoch ms
    let color: String?      // yellow/blue/pink/orange

    // Convenience: human-readable date from timestamp
    var highlightDate: Date {
        Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
    }
}

// MARK: - Sync Result (returned by KindleSyncEngine after a sync run)

struct SyncResult {
    let booksProcessed: Int
    let newHighlightsCount: Int
    let completedAt: Date
}

// MARK: - Sync Error

enum SyncError: Error, LocalizedError {
    case sessionExpired
    case networkError(Error)
    case decodingError(Error)
    case notesError(String)
    case alreadyInProgress
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Your Amazon session has expired. Please sign in again."
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        case .decodingError(let e):
            return "Data parsing error: \(e.localizedDescription)"
        case .notesError(let msg):
            return "Apple Notes error: \(msg)"
        case .alreadyInProgress:
            return "A sync is already in progress."
        case .permissionDenied(let msg):
            return "Permission denied: \(msg)"
        }
    }
}
