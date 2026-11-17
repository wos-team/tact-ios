import SwiftUI
import WebKit

struct SignInView: UIViewRepresentable {
    let onConnected: ([SessionCookie]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onConnected: onConnected) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: TACTClient.login))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var completed = false
        private let onConnected: ([SessionCookie]) -> Void

        init(onConnected: @escaping ([SessionCookie]) -> Void) {
            self.onConnected = onConnected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !completed, let url = webView.url,
                  url.scheme == "https", url.host == TACTClient.host,
                  url.path.hasPrefix("/portal"), !url.path.hasPrefix("/portal/login") else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !self.completed else { return }
                let tactCookies = cookies.filter { cookie in
                    // Only TACT-origin cookies are needed for the native API client.
                    cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        .caseInsensitiveCompare(TACTClient.host) == .orderedSame
                }.map(SessionCookie.init).filter { $0.applies(to: "/direct/assignment/my.json") }

                guard !tactCookies.isEmpty else { return }
                self.completed = true
                self.onConnected(tactCookies)
            }
        }
    }
}
