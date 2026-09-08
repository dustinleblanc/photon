import SwiftUI
import WebKit
import AppKit

/// Renders Proton's own hosted human-verification widget (verify.proton.me)
/// exactly the way Proton's iOS/macOS apps do -- same URL shape, same
/// WKScriptMessageHandler name ("iOS", even on macOS -- confirmed from
/// Proton's open-sourced HumanVerifyViewModel.swift), same postMessage
/// protocol. This is the legitimate flow: no captcha-solving shortcuts,
/// just the real widget Proton already built for this.
struct HumanVerificationView: View {
    let challenge: HVChallenge
    let onSolved: (HVProof) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Verify you're human")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }
            .padding()

            HumanVerificationWebView(challenge: challenge, onSolved: onSolved)
                .frame(width: 400, height: 520)
        }
    }
}

private struct HumanVerificationWebView: NSViewRepresentable {
    let challenge: HVChallenge
    let onSolved: (HVProof) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSolved: onSolved)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        // "iOS" is not a typo -- Proton's hosted verify page posts to a
        // handler literally named "iOS" regardless of host platform.
        contentController.add(context.coordinator, name: "iOS")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "ipad"
        webView.load(URLRequest(url: verificationURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    private var verificationURL: URL {
        var components = URLComponents(string: "https://verify.proton.me/")!
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        components.queryItems = [
            URLQueryItem(name: "token", value: challenge.token),
            URLQueryItem(name: "methods", value: challenge.methods.joined(separator: ",")),
            URLQueryItem(name: "theme", value: isDark ? "1" : "2"),
            URLQueryItem(name: "locale", value: Locale.current.identifier),
            URLQueryItem(name: "defaultCountry", value: Locale.current.region?.identifier ?? ""),
            URLQueryItem(name: "embed", value: "true"),
        ]
        return components.url!
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onSolved: (HVProof) -> Void

        init(onSolved: @escaping (HVProof) -> Void) {
            self.onSolved = onSolved
        }

        // Mirrors HumanVerifyViewModel.interpretMessage from Proton's
        // protoncore_ios: messages are JSON strings with a "type" field;
        // we only need to act on HUMAN_VERIFICATION_SUCCESS.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iOS",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String
            else { return }

            guard type == "HUMAN_VERIFICATION_SUCCESS",
                  let payload = json["payload"] as? [String: Any],
                  let token = payload["token"] as? String,
                  let method = payload["type"] as? String
            else { return }

            onSolved(HVProof(method: method, token: token))
        }
    }
}
