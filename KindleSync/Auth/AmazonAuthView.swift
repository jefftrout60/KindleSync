import SwiftUI
import WebKit

struct AmazonAuthView: NSViewRepresentable {
    let onLoginSuccess: ([HTTPCookie]) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        let url = URL(string: "https://read.amazon.com/notebook")!
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginSuccess: onLoginSuccess)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoginSuccess: ([HTTPCookie]) -> Void
        private var hasCalledBack = false

        init(onLoginSuccess: @escaping ([HTTPCookie]) -> Void) {
            self.onLoginSuccess = onLoginSuccess
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            guard url.host?.hasSuffix("amazon.com") == true,
                  url.path == "/notebook" else { return }
            guard !hasCalledBack else { return }
            hasCalledBack = true
            extractCookies(from: webView)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            // Navigation errors are silently ignored — user will see the error in the WebView
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // Provisional navigation errors (DNS, connection refused) — silently ignore
        }

        private func extractCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore
                .httpCookieStore.getAllCookies { [weak self] cookies in
                    guard let self else { return }
                    let amazonCookies = cookies.filter {
                        $0.domain.hasSuffix("amazon.com") || $0.domain.hasSuffix(".amazon.com")
                    }
                    self.onLoginSuccess(amazonCookies)
                }
        }
    }
}

// MARK: - Auth Sheet View

struct AmazonAuthSheet: View {
    let onLoginSuccess: ([HTTPCookie]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Amazon Account")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(.bar)

            AmazonAuthView { cookies in
                onLoginSuccess(cookies)
                dismiss()
            }
        }
        .frame(width: 480, height: 640)
    }
}
