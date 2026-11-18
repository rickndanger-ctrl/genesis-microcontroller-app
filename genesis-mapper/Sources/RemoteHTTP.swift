import Foundation
import Network

struct RemoteHTTPResponse {
    var status: Int = 200
    var contentType = "application/json"
    var data: Data
    static func json<T:Encodable>(_ value:T,status:Int = 200) -> RemoteHTTPResponse {
        do {return RemoteHTTPResponse(status:status,data:try JSONEncoder().encode(value))}
        catch {return .error(500,"Could not encode response.")}
    }
    static func error(_ status:Int,_ message:String) -> RemoteHTTPResponse { .json(["error":message],status:status) }
}

final class RemoteHTTPServer: @unchecked Sendable {
    let queue = DispatchQueue(label:"genesis.remote.http",qos:.userInitiated)
    private var listener:NWListener?
    private var peers:[UUID:NWConnection] = [:]
    /// Connections that have not yet sent a complete request. Touched only on `queue`.
    private var waiting:Set<UUID> = []
    private let port:UInt16
    /// Set for the Wi-Fi listener: TLS with this Mac's own certificate, on every
    /// network interface. Nil for the loopback listener that Tailscale Serve relays to.
    private let tls:SecIdentity?
    /// Which remote addresses the Wi-Fi listener lets in.
    private let admits:(String)->Bool
    private let handler:@MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    var stateChanged:((String)->Void)?
    /// The handler decides who may ask: it holds the list of paired devices,
    /// which lives on the main actor and can change while the server runs.
    init(port:UInt16=18765,tls:SecIdentity?=nil,admits:@escaping (String)->Bool={_ in true},handler:@escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse) {self.port=port;self.tls=tls;self.admits=admits;self.handler=handler}
    func start() throws {
        let parameters:NWParameters
        if let tls {
            let options = NWProtocolTLS.Options()
            guard let identity = sec_identity_create(tls) else {throw RemoteFault(status:500,message:"Wi-Fi certificate unusable.")}
            sec_protocol_options_set_local_identity(options.securityProtocolOptions,identity)
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions,.TLSv12)
            parameters = NWParameters(tls:options)
        } else {
            parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        }
        parameters.allowLocalEndpointReuse = false
        let listener = tls == nil ? try NWListener(using:parameters) : try NWListener(using:parameters,on:NWEndpoint.Port(rawValue:port)!)
        self.listener = listener
        let network = tls != nil
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else {return}
            switch state {
            case .ready:self.stateChanged?(network ? "Listening on this Wi-Fi network":"Listening on this Mac")
            case .failed(_):self.stateChanged?(network ? "Wi-Fi pairing could not start. Port \(self.port) may already be in use.":"Remote service could not start. Port 18765 may already be in use.")
            case .cancelled:self.stateChanged?(network ? "Wi-Fi pairing is off":"Remote access is off")
            default:break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {connection.cancel();return}
            if network {
                guard case let .hostPort(host,_) = connection.endpoint,self.admits("\(host)") else {connection.cancel();return}
            }
            guard self.peers.count<12 else {connection.cancel();return}
            let id = UUID(); self.peers[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {case .cancelled,.failed(_):self?.peers.removeValue(forKey:id);self?.waiting.remove(id);default:break}
            }
            connection.start(queue:self.queue)
            self.waiting.insert(id)
            // A connection that has not delivered a whole request within five
            // seconds is dropped, so stalled or abandoned connections cannot
            // hold the few slots there are. A request being served keeps its 20.
            self.queue.asyncAfter(deadline:.now()+5) { [weak self,weak connection] in
                guard let self,self.waiting.contains(id) else{return}
                connection?.cancel();self.peers.removeValue(forKey:id);self.waiting.remove(id)
            }
            self.queue.asyncAfter(deadline:.now()+20) { [weak self,weak connection] in connection?.cancel();self?.peers.removeValue(forKey:id);self?.waiting.remove(id) }
            self.receive(connection,accumulated:Data(),id:id)
        }
        listener.start(queue:queue)
    }
    func stop() { queue.async { [weak self] in self?.listener?.cancel();self?.listener=nil;self?.peers.values.forEach{$0.cancel()};self?.peers.removeAll() } }
    private func receive(_ connection:NWConnection,accumulated:Data,id:UUID) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16_384) { [weak self] data,_,complete,error in
            guard let self else {connection.cancel();return}
            var all=accumulated;if let data {all.append(data)}
            do {
                if var request=try RemoteHTTPRequest.parse(all) {
                    request.viaNetwork = self.tls != nil
                    self.waiting.remove(id)
                    if ["POST","PUT"].contains(request.method),request.headers["content-type"]?.lowercased().hasPrefix("application/json") != true {self.send(.error(415,"JSON content type required."),on:connection);return}
                    Task { @MainActor in let response = await self.handler(request);self.queue.async {self.send(response,on:connection)} }
                } else if complete || error != nil {self.send(.error(400,"Incomplete request."),on:connection)}
                else {self.receive(connection,accumulated:all,id:id)}
            } catch let error as RemoteFault {self.send(.error(error.status,error.message),on:connection)}
            catch {self.send(.error(400,"Invalid request."),on:connection)}
        }
    }
    private func send(_ response:RemoteHTTPResponse,on connection:NWConnection) {
        let reason = response.status == 200 ? "OK":"Error"
        var payload=Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; sandbox\r\n\r\n".utf8)
        payload.append(response.data)
        connection.send(content:payload,completion:.contentProcessed{_ in connection.cancel()})
    }
}
