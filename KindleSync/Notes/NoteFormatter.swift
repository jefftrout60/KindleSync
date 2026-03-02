import Foundation

struct NoteFormatter {
    static func buildHTML(book: StoredBook) -> String {
        let sorted = book.highlights.sorted { $0.startPosition < $1.startPosition }
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
            parts.append("<h3>\(escape(highlight.location))</h3>")
            parts.append("<p>\"\(escape(highlight.text))\"</p>")

            if let note = highlight.note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("<p><i>📝 \(escape(note))</i></p>")
            }

            let dateStr = formatDate(highlight.highlightDate)
            let colorStr = highlight.color.map { " · \($0.capitalized)" } ?? ""
            parts.append("<p><i>\(dateStr)\(colorStr)</i></p>")
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

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
