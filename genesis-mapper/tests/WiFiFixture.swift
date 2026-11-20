import Foundation

/// A stand-in companion for the phone's Wi-Fi route test: the real Wi-Fi
/// listener (TLS, all interfaces) on 18798 and a plain loopback listener on
/// 18797 that plays the Tailscale route. Prints the certificate fingerprint,
/// answers /v1/status for one bearer token, then quits after the given seconds.
@main struct WiFiFixture {
    @MainActor static func main() async throws {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("amc-wifi-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let identity = try WiFiIdentity.loadOrCreate(in: folder)
        func handler(_ label: String) -> @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse {
            { request in
                guard request.headers["authorization"] == "Bearer fixture-token-0123456789abcdef0123456789" else { return .error(401, "unpaired") }
                return .json(["route": label, "network": request.viaNetwork ? "yes" : "no", "method": request.method])
            }
        }
        let wifi = RemoteHTTPServer(port: 18798, tls: identity.identity, admits: WiFiIdentity.isPrivate, handler: handler("wifi"))
        let tailnet = RemoteHTTPServer(port: 18797, handler: handler("tailnet"))
        try wifi.start(); try tailnet.start()
        print("PIN", identity.fingerprint)
        print("HOST", WiFiIdentity.localHostName ?? "none")
        fflush(stdout)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        wifi.stop(); tailnet.stop()
    }
}
