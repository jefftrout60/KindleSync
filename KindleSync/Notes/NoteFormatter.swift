import Foundation

struct NoteFormatter {
    static func buildHTML(book: StoredBook) -> String {
        let sorted = book.highlights.sorted { locationNumber($0.location) < locationNumber($1.location) }
        let syncDate = formatDate(Date())
        let count = sorted.count

        var parts: [String] = []

        // Header
        parts.append("<h2>\(escape(book.title))</h2>")
        parts.append("<p>\(escape(book.author))</p>")
        parts.append("<p><i>\(count) highlight\(count == 1 ? "" : "s") · Last synced: \(syncDate)</i></p>")
        parts.append("<hr>")

        // Highlights
        for highlight in sorted {
            let colorSuffix = highlight.color.map { " · \($0.capitalized)" } ?? ""
            parts.append("<h3>\(escape(highlight.location))\(colorSuffix)</h3>")
            parts.append("<p>\"\(escape(highlight.text))\"</p>")

            if let note = highlight.note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("<p><i>Jeff's Note: \(escape(note))</i></p>")
            }

            if highlight.timestamp > 0 {
                parts.append("<p><i>\(formatDate(highlight.highlightDate))</i></p>")
            }

            parts.append("<br>")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Note Title

    static func noteTitle(for book: StoredBook) -> String {
        "\(book.title) by \(book.author)"
    }

    // MARK: - Private

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    // Extract the numeric position from a location string like "Location: 3,680" or "Page: 16"
    private static func locationNumber(_ location: String) -> Int {
        let stripped = location.replacingOccurrences(of: ",", with: "")
        var digits = ""
        for c in stripped {
            if c.isNumber { digits.append(c) }
            else if !digits.isEmpty { break }
        }
        return Int(digits) ?? 0
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
