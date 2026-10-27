import SwiftUI
import Network

@main
struct WatchSpikeApp: App {
    @StateObject private var client = SpikeClient()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(client) }
    }
}

struct ContentView: View {
    @EnvironmentObject var client: SpikeClient
    @State private var question = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(client.connectionText).font(.footnote)
                Text("Wisp: \(client.wispState)").font(.headline)
                if let pending = client.pendingConfirmation {
                    Text(pending.title).font(.headline)
                    Text(pending.detail).font(.footnote)
                    HStack {
                        Button("Deny") { client.resolve(allow: false) }.tint(.red)
                        Button("Allow") { client.resolve(allow: true) }.tint(.green)
                    }
                } else {
                    TextField("Ask Wisp", text: $question)
                        .onSubmit { client.ask(question); question = "" }
                }
                if !client.lastReply.isEmpty { Text(client.lastReply).font(.footnote) }
                Button("Connect localhost") { client.connect(to: .hostPort(host: "127.0.0.1", port: 47900)) }
            }
        }
        .onAppear { client.startBrowsing() }
    }
}

struct PendingConfirmation { let id: String; let title: String; let detail: String }

@MainActor
final class SpikeClient: ObservableObject {
    @Published var connectionText = "searching…"
    @Published var wispState = "?"
    @Published var lastReply = ""
    @Published var pendingConfirmation: PendingConfirmation?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_wispwatch._tcp", domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.connectionText = "browse: \(state)" }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor in self?.connect(to: endpoint) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func connect(to endpoint: NWEndpoint) {
        connection?.cancel()
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.connectionText = "conn: \(state)"
                if case .ready = state { self?.send(["type": "status"]) }
            }
        }
        connection.start(queue: .main)
        self.connection = connection
        buffer = Data()
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, connection === self.connection else { return }
                if let data { self.buffer.append(data) }
                while let newlineIndex = self.buffer.firstIndex(of: 0x0A) {
                    let line = self.buffer.subdata(in: self.buffer.startIndex..<newlineIndex)
                    self.buffer.removeSubrange(self.buffer.startIndex...newlineIndex)
                    self.handle(line)
                }
                if error == nil { self.receiveLoop(connection) }
            }
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "status": wispState = message["state"] as? String ?? "?"
        case "reply": lastReply = message["text"] as? String ?? ""; pendingConfirmation = nil
        case "confirmation":
            pendingConfirmation = PendingConfirmation(id: message["id"] as? String ?? "",
                                                      title: message["title"] as? String ?? "",
                                                      detail: message["detail"] as? String ?? "")
        default: break
        }
    }

    func ask(_ text: String) { send(["type": "ask", "text": text]) }
    func resolve(allow: Bool) {
        guard let pending = pendingConfirmation else { return }
        send(["type": "confirm", "id": pending.id, "allow": allow])
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
