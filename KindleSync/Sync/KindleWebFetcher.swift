import Foundation
import WebKit

@MainActor
final class KindleWebFetcher: NSObject {

    // MARK: - Private nested types for deserializing JS result

    private struct JSResult: Decodable {
        struct JSBook: Decodable {
            let asin: String
            let title: String
            let authors: String
            let coverImageURL: String?
        }
        struct JSHighlight: Decodable {
            let id: String
            let text: String
            let note: String?
            let location: String
            let startPosition: Int
            let timestamp: Int64
            let color: String?
        }
        let books: [JSBook]
        let highlightsByASIN: [String: [JSHighlight]]
    }

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    func fetchAll() async throws -> ([KindleBook], [String: [KindleHighlight]]) {
        let wv = WKWebView(frame: .zero)
        wv.navigationDelegate = self
        self.webView = wv
        defer { self.webView = nil }

        // Load the notebook page (inherits session cookies from default data store)
        try await withCheckedThrowingContinuation { continuation in
            self.loadContinuation = continuation
            wv.load(URLRequest(url: URL(string: "https://read.amazon.com/notebook")!))
        }

        // Run the JS fetch script
        let rawResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            wv.callAsyncJavaScript(kindleFetchScript, arguments: [:], in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error):
                    print("[KindleSync] ❌ JS error: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let anyResult = rawResult,
              let jsonData = try? JSONSerialization.data(withJSONObject: anyResult) else {
            throw SyncError.decodingError(NSError(domain: "KindleWebFetcher", code: 0,
                userInfo: [NSLocalizedDescriptionKey: "JS returned unexpected format"]))
        }

        let jsResult: JSResult
        do {
            jsResult = try JSONDecoder().decode(JSResult.self, from: jsonData)
        } catch {
            print("[KindleSync] ❌ Decode error: \(error)")
            throw SyncError.decodingError(error)
        }

        let books = jsResult.books.map {
            KindleBook(asin: $0.asin, title: $0.title, authors: $0.authors, coverImageURL: $0.coverImageURL)
        }
        let highlightsByASIN = jsResult.highlightsByASIN.mapValues { jsHighlights in
            jsHighlights.map { jh in
                KindleHighlight(highlightId: jh.id, highlight: jh.text, note: jh.note,
                                startPosition: jh.startPosition, timestamp: jh.timestamp,
                                color: jh.color, locationValue: jh.location)
            }
        }

        let totalHighlights = highlightsByASIN.values.reduce(0) { $0 + $1.count }
        print("[KindleSync] Fetched \(books.count) books, \(totalHighlights) total highlights")

        return (books, highlightsByASIN)
    }
}

// MARK: - WKNavigationDelegate

extension KindleWebFetcher: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard let url = webView.url else { return }
            let urlString = url.absoluteString
            // Amazon redirects through several intermediate pages before landing on /notebook.
            // Only resume once we've reached the final destination to avoid running JS injection
            // on an intermediate page. Auth pages (ap/signin, ap/mfa, ap/cvf) mean session expired.
            if urlString.contains("/ap/signin") || urlString.contains("/ap/mfa") || urlString.contains("/ap/cvf") {
                self.loadContinuation?.resume(throwing: SyncError.sessionExpired)
                self.loadContinuation = nil
            } else if urlString.contains("read.amazon.com/notebook") {
                self.loadContinuation?.resume()
                self.loadContinuation = nil
            }
            // Intermediate redirect — ignore and wait for final destination
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: SyncError.networkError(error))
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: SyncError.networkError(error))
            self.loadContinuation = nil
        }
    }
}

// MARK: - JavaScript Fetch Script

// NOTE: All regex backslashes (\\s, \\d, \\w) are doubled because Swift string literals
// require \\ to produce a single literal backslash in the resulting JS string.
private let kindleFetchScript = """
function fnv32a(str) {
    let h = 0x811c9dc5 >>> 0;
    for (let i = 0; i < str.length; i++) {
        h ^= str.charCodeAt(i);
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h.toString(16).padStart(8, '0');
}

function parsePos(s) {
    const m = s.match(/(?:Location|Page)[:\\s]+([\\d,]+)/i) || s.match(/([\\d,]+)/);
    return m ? parseInt(m[1].replace(/,/g, '')) : 0;
}

function parseTs(s) {
    const m = s.match(/(?:on\\s+)?(?:\\w+,\\s+)?(\\w+\\s+\\d+,?\\s+\\d{4})/i);
    if (!m) return 0;
    const d = new Date(m[1]);
    return isNaN(d) ? 0 : d.getTime();
}

async function fetchBooks() {
    const all = [];
    let tok = null;
    do {
        let url = '/kindle-library/search?query=&libraryType=BOOKS&sortType=recency&querySize=50';
        if (tok) url += '&paginationToken=' + encodeURIComponent(tok);
        const r = await fetch(url);
        if (!r.ok) throw new Error('books HTTP ' + r.status);
        const d = await r.json();
        all.push(...(d.itemsList || []));
        tok = d.paginationToken || null;
        if (tok) await new Promise(res => setTimeout(res, 300));
    } while (tok);
    return all;
}

async function fetchHighlights(asin) {
    const all = [];
    let tok = '', cls = '';
    do {
        const url = '/notebook?asin=' + encodeURIComponent(asin) +
            '&contentLimitState=' + encodeURIComponent(cls) +
            '&token=' + encodeURIComponent(tok);
        const r = await fetch(url);
        if (!r.ok) break;
        const doc = new DOMParser().parseFromString(await r.text(), 'text/html');
        // Query highlight elements directly — more resilient than relying on outer container
        for (const hlEl of doc.querySelectorAll('.kp-notebook-highlight')) {
            const text = hlEl.textContent.trim();
            if (!text) continue;
            // Walk up to the card-level container (.a-spacing-base wraps highlight + note + metadata)
            const container = hlEl.closest('.a-spacing-base') || hlEl.closest('.a-row') || hlEl.parentElement;
            const noteEl = container ? container.querySelector('.kp-notebook-note') : null;
            const rawNote = noteEl ? noteEl.textContent.trim().replace(/^Note[:\\s]*/i, '').trim() : '';
            const metaEl = container ? container.querySelector('.kp-notebook-metadata') : null;
            const meta = metaEl ? metaEl.textContent.trim() : '';
            // meta format: "Yellow highlight | Page: 16 | Added on ..."
            // parts[0] = color indicator, parts[1] = location, parts[2]+ = date (if present)
            const metaParts = meta.split('|').map(p => p.trim());
            const loc = metaParts[1] || metaParts[0] || '';
            // Date: first try meta[2]+, then scan the card for "Added on ..." text
            const dateFromMeta = metaParts.slice(2).join(' ');
            const cardText = container ? container.textContent : '';
            const addedOnMatch = cardText.match(/added\\s+on\\b.{0,80}/i);
            const dateSource = dateFromMeta || (addedOnMatch ? addedOnMatch[0] : '');
            // Color: first try CSS class (kp-color-yellow), then parse word from meta[0]
            const cm = hlEl.className.match(/kp-color-(\\w+)/);
            const colorFromMeta = metaParts[0].match(/(yellow|blue|pink|orange)/i);
            const color = cm ? cm[1] : (colorFromMeta ? colorFromMeta[1].toLowerCase() : null);
            all.push({
                id: asin + '#' + fnv32a(text + loc),
                text,
                note: (rawNote && rawNote !== 'Note') ? rawNote : null,
                location: loc,
                startPosition: parsePos(loc),
                timestamp: parseTs(dateSource),
                color
            });
        }
        const nt = doc.querySelector('.kp-notebook-annotations-next-page-start');
        const ns = doc.querySelector('.kp-notebook-content-limit-state');
        tok = nt ? (nt.value || nt.getAttribute('data-value') || '') : '';
        cls = ns ? (ns.value || ns.getAttribute('data-value') || '') : '';
    } while (tok);
    return all;
}

const bks = await fetchBooks();
const h = {};
for (let i = 0; i < bks.length; i++) {
    h[bks[i].asin] = await fetchHighlights(bks[i].asin);
    if (i < bks.length - 1) await new Promise(res => setTimeout(res, 500));
}
return {
    books: bks.map(b => ({
        asin: b.asin || '',
        title: b.title || '',
        authors: Array.isArray(b.authors) ? b.authors.join(', ') : (b.authors || ''),
        coverImageURL: b.productUrl
            ? b.productUrl.replace(/\\._[A-Z0-9,]+_\\.jpg$/, '.jpg')
            : null
    })),
    highlightsByASIN: h
};
"""
