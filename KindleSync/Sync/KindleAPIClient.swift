import Foundation

struct KindleAPIClient {
    private static let baseURL = "https://read.amazon.com/api/notebook"
    private static let referer = "https://read.amazon.com/notebook"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Fetch Books (paginated page)

    static func fetchBooks(
        cookies: [HTTPCookie],
        token: String? = nil,
        session: URLSession = .shared
    ) async throws -> BookListResponse {
        var components = URLComponents(string: baseURL)!
        var queryItems: [URLQueryItem] = [
            .init(name: "library", value: "list"),
            .init(name: "type",    value: "BOOK"),
            .init(name: "batchSize", value: "50")
        ]
        if let token { queryItems.append(.init(name: "token", value: token)) }
        components.queryItems = queryItems

        let request = makeRequest(url: components.url!, cookies: cookies)
        return try await perform(request: request, as: BookListResponse.self, session: session)
    }

    // MARK: - Fetch Highlights (paginated page)

    static func fetchHighlights(
        asin: String,
        cookies: [HTTPCookie],
        token: String? = nil,
        session: URLSession = .shared
    ) async throws -> HighlightListResponse {
        var components = URLComponents(string: baseURL)!
        var queryItems: [URLQueryItem] = [
            .init(name: "asin",      value: asin),
            .init(name: "type",      value: "HIGHLIGHT"),
            .init(name: "batchSize", value: "50")
        ]
        if let token { queryItems.append(.init(name: "token", value: token)) }
        components.queryItems = queryItems

        let request = makeRequest(url: components.url!, cookies: cookies)
        return try await perform(request: request, as: HighlightListResponse.self, session: session)
    }

    // MARK: - Private Helpers

    private static func makeRequest(url: URL, cookies: [HTTPCookie]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)
        for (key, value) in cookieHeader {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(referer,            forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent,          forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func perform<T: Decodable>(
        request: URLRequest,
        as type: T.Type,
        session: URLSession
    ) async throws -> T {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.networkError(URLError(.badServerResponse))
        }

        // Session expiry: redirect to signin
        if let finalURL = http.url, finalURL.absoluteString.contains("ap/signin") {
            throw SyncError.sessionExpired
        }

        // Session expiry: HTTP status
        if http.statusCode == 401 || http.statusCode == 403 {
            throw SyncError.sessionExpired
        }

        // Session expiry: JSON error code
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? String,
           ["UNAUTHORIZED", "FORBIDDEN", "SESSION_EXPIRED"].contains(code) {
            throw SyncError.sessionExpired
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SyncError.decodingError(error)
        }
    }
}
