import Foundation

/// Runs in the iOS simulator against genesis-mapper/tests/WiFiFixture.swift on
/// this Mac. Uses the app's real RemoteClient: pinned TLS to the Mac's .local
/// name, refusal of a wrong certificate, and falling back to the second route.
///   wifi-route-integration <mac>.local <pin>
@main struct WiFiRouteIntegration {
    struct Answer: Decodable { let route: String; let network: String; let method: String }
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print(ok ? "ok  " : "FAIL", what); if !ok { failures += 1 } }

    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("usage: wifi-route-integration <host.local> <pin>"); exit(2) }
        let lan = "https://\(args[1]):18798", pin = args[2]
        let wrongPin = String(repeating: "A", count: 43)
        let token = "fixture-token-0123456789abcdef0123456789"
        let tailnet = "http://127.0.0.1:18797"   // plays Tailscale; plain loopback is allowed in debug simulator builds

        func ask(_ host: RemoteHost, _ client: RemoteClient, method: String = "GET") async -> Answer? {
            try? await client.fetch(Answer.self, host: host, token: token, path: "/v1/status", method: method,
                                    body: method == "GET" ? nil : Data("{}".utf8))
        }

        // Wi-Fi only, right certificate.
        let wifiOnly = RemoteHost(id: "a", name: "Mac", baseURL: lan, hostID: nil, lanURL: lan, pin: pin)
        let a = await ask(wifiOnly, RemoteClient())
        check(a?.route == "wifi" && a?.network == "yes", "reaches the Mac over Wi-Fi by its .local name with the pinned certificate")

        // Wi-Fi only, wrong certificate: refused, never reaches the handler with the token.
        let impostor = RemoteHost(id: "b", name: "Mac", baseURL: lan, hostID: nil, lanURL: lan, pin: wrongPin)
        check(await ask(impostor, RemoteClient()) == nil, "refuses a Mac whose certificate does not match the QR code")

        // Both routes, Wi-Fi certificate wrong: falls back to Tailscale, and a Send may go too (never reached the Mac).
        let both = RemoteHost(id: "c", name: "Mac", baseURL: tailnet, hostID: nil, lanURL: lan, pin: wrongPin)
        let fallbackClient = RemoteClient()
        check(await ask(both, fallbackClient)?.route == "tailnet", "falls back to Tailscale when Wi-Fi fails")
        check(await ask(both, fallbackClient, method: "POST")?.route == "tailnet", "a Send falls back when Wi-Fi never connected")
        check(fallbackClient.routes.ordered(both).first?.route == .tailnet, "sticks with Tailscale for a while after Wi-Fi failed")

        // Both routes, Wi-Fi unreachable (nothing listening): falls back.
        let closed = RemoteHost(id: "d", name: "Mac", baseURL: tailnet, hostID: nil, lanURL: "https://\(args[1]):18796", pin: pin)
        check(await ask(closed, RemoteClient())?.route == "tailnet", "falls back when nothing answers on Wi-Fi")

        // Both routes, Wi-Fi fine: Wi-Fi wins.
        let good = RemoteHost(id: "e", name: "Mac", baseURL: tailnet, hostID: nil, lanURL: lan, pin: pin)
        check(await ask(good, RemoteClient())?.route == "wifi", "prefers Wi-Fi when it works")

        if failures > 0 { print("\(failures) Wi-Fi route checks failed"); exit(1) }
        print("PASS Wi-Fi route integration")
    }
}
