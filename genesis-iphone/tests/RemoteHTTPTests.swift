import Foundation

@main struct RemoteHTTPTests {
    @MainActor static func main() async throws {
        let fixtureToken=UUID().uuidString
        var handled=0
        let server=RemoteHTTPServer(token:fixtureToken,port:18766) { request in
            handled += 1
            return .json(["ok":true])
        }
        try server.start()
        defer{server.stop()}
        try await Task.sleep(nanoseconds:250_000_000)
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=4
        let client=URLSession(configuration:config)
        func status(token:String?,origin:String?=nil) async throws -> Int {
            var request=URLRequest(url:URL(string:"http://127.0.0.1:18766/v1/status")!)
            if let token{request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")}
            if let origin{request.setValue(origin,forHTTPHeaderField:"Origin")}
            let (_,response)=try await client.data(for:request)
            return (response as! HTTPURLResponse).statusCode
        }
        guard try await status(token:nil)==401 else{fatalError("Missing auth accepted")}
        guard try await status(token:"bad")==401 else{fatalError("Wrong auth accepted")}
        guard try await status(token:fixtureToken,origin:"https://untrusted.example")==400 else{fatalError("Browser origin accepted")}
        guard try await status(token:fixtureToken)==200 else{fatalError("Paired auth failed")}
        guard handled==1 else{fatalError("Unauthorized request reached route")}
        let (_,response)=try await client.data(for:{()->URLRequest in var r=URLRequest(url:URL(string:"http://127.0.0.1:18766/v1/status")!);r.setValue("Bearer "+fixtureToken,forHTTPHeaderField:"Authorization");return r}())
        let headers=(response as! HTTPURLResponse)
        guard headers.value(forHTTPHeaderField:"Cache-Control")=="no-store" else{fatalError("Sensitive response caching enabled")}
        print("PASS 6 authenticated loopback HTTP checks; no app controls invoked")
    }
}
