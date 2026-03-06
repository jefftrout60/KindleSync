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

        // Intercept the response to /notebook before the page body renders.
        // Cancelling here prevents any flash of the notebook content.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url,
                  url.host?.hasSuffix("amazon.com") == true,
                  url.path == "/notebook",
                  !hasCalledBack else {
                decisionHandler(.allow)
                return
            }
            hasCalledBack = true
            decisionHandler(.cancel) // prevent the page from rendering
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
                        $0.domain == "amazon.com" || $0.domain.hasSuffix(".amazon.com")
                    }
                    self.onLoginSuccess(amazonCookies)
                }
        }
    }
}

// MARK: - Auth Sheet View

struct AmazonAuthSheet: View {
    let onLoginSuccess: ([HTTPCookie]) -> Void
    @State private var loginSucceeded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connect Amazon Account")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(.bar)

            ZStack {
                AmazonAuthView { cookies in
                    loginSucceeded = true
                    onLoginSuccess(cookies)
                }
                // Blank overlay hides the post-login notebook page flash
                if loginSucceeded {
                    Color(NSColor.windowBackgroundColor)
                }
            }
        }
        .frame(width: 480, height: 640)
    }
}
