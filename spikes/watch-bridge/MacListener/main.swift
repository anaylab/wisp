// Spike: stand-in for Wisp's future RemoteControlBridge.
// Advertises _wispwatch._tcp over Bonjour, speaks newline-delimited JSON.
//   watch -> mac: {"type":"status"} | {"type":"ask","text":"..."} | {"type":"confirm","id":"..","allow":true}
//   mac -> watch: {"type":"status","state":"idle"} | {"type":"reply","text":".."} | {"type":"confirmation","id":"..","title":"..","detail":".."}
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)
let port: NWEndpoint.Port = 47900
let parameters = NWParameters.tcp
let listener = try NWListener(using: parameters, on: port)
listener.service = NWListener.Service(name: "Wisp Spike", type: "_wispwatch._tcp")

func send(_ object: [String: Any], on connection: NWConnection) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    connection.send(content: data, completion: .contentProcessed { _ in })
}

func receive(on connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
        var buffer = buffer
        if let data { buffer.append(data) }
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            handle(line: line, on: connection)
        }
        if isComplete || error != nil { print("client gone"); return }
        receive(on: connection, buffer: buffer)
    }
}

func handle(line: Data, on connection: NWConnection) {
    guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let type = message["type"] as? String else { return }
    print("<-", message)
    switch type {
    case "status":
        send(["type": "status", "state": "idle"], on: connection)
    case "ask":
        let text = message["text"] as? String ?? ""
        send(["type": "status", "state": "thinking"], on: connection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            send(["type": "confirmation", "id": "c1", "title": "Send message", "detail": "To Mom: \(text)"], on: connection)
        }
    case "confirm":
        let allowed = message["allow"] as? Bool ?? false
        send(["type": "reply", "text": allowed ? "Done." : "Cancelled."], on: connection)
        send(["type": "status", "state": "idle"], on: connection)
    default: break
    }
}

listener.newConnectionHandler = { connection in
    print("client connected from", connection.endpoint)
    connection.start(queue: .main)
    send(["type": "status", "state": "idle"], on: connection)
    receive(on: connection, buffer: Data())
}
listener.stateUpdateHandler = { print("listener:", $0) }
listener.start(queue: .main)
dispatchMain()
