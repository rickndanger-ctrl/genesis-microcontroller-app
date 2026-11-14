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
    private let token:String
    private let port:UInt16
    private let handler:@MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    var stateChanged:((String)->Void)?
    init(token:String,port:UInt16=18765,handler:@escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse) {self.token=token;self.port=port;self.handler=handler}
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using:parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:self?.stateChanged?("Listening on this Mac")
            case .failed(_):self?.stateChanged?("Remote service could not start. Port 18765 may already be in use.")
            case .cancelled:self?.stateChanged?("Remote access is off")
            default:break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {connection.cancel();return}
            guard self.peers.count<12 else {connection.cancel();return}
            let id = UUID(); self.peers[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {case .cancelled,.failed(_):self?.peers.removeValue(forKey:id);default:break}
            }
            connection.start(queue:self.queue)
            self.queue.asyncAfter(deadline:.now()+20) { [weak self,weak connection] in connection?.cancel();self?.peers.removeValue(forKey:id) }
            self.receive(connection,accumulated:Data())
        }
        listener.start(queue:queue)
    }
    func stop() { queue.async { [weak self] in self?.listener?.cancel();self?.listener=nil;self?.peers.values.forEach{$0.cancel()};self?.peers.removeAll() } }
    private func receive(_ connection:NWConnection,accumulated:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16_384) { [weak self] data,_,complete,error in
            guard let self else {connection.cancel();return}
            var all=accumulated;if let data {all.append(data)}
            do {
                if let request=try RemoteHTTPRequest.parse(all) {
                    guard RemotePolicy.equalToken(request.headers["authorization"] ?? "","Bearer "+self.token) else {self.send(.error(401,"Pair this iPhone with the Mac first."),on:connection);return}
                    if ["POST","PUT"].contains(request.method),request.headers["content-type"]?.lowercased().hasPrefix("application/json") != true {self.send(.error(415,"JSON content type required."),on:connection);return}
                    Task { @MainActor in let response = await self.handler(request);self.queue.async {self.send(response,on:connection)} }
                } else if complete || error != nil {self.send(.error(400,"Incomplete request."),on:connection)}
                else {self.receive(connection,accumulated:all)}
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
