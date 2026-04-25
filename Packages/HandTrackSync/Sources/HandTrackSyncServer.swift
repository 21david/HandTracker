import Foundation
import Combine
import Network

#if os(macOS)
@MainActor
final class HandTrackSyncServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var statusMessage = "Sync server stopped"

    private let store: HandTrackStore
    private var listener: NWListener?

    init(store: HandTrackStore) {
        self.store = store
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: 8787)
            listener.service = NWListener.Service(name: "HandTrack Mac", type: "_handtrack._tcp")
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handle(state)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            statusMessage = "Sync server failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        statusMessage = "Sync server stopped"
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            statusMessage = "Sync server running on port 8787"
        case .failed(let error):
            isRunning = false
            statusMessage = "Sync server failed: \(error.localizedDescription)"
            listener = nil
        case .cancelled:
            isRunning = false
            statusMessage = "Sync server stopped"
            listener = nil
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 655_536) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { return }
                let response = self.response(for: data ?? Data())
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for requestData: Data) -> Data {
        guard let request = String(data: requestData, encoding: .utf8) else {
            return httpResponse(status: "400 Bad Request", body: "Bad request")
        }

        if request.hasPrefix("GET /health") {
            return httpResponse(status: "200 OK", body: #"{"status":"ok"}"#)
        }

        guard request.hasPrefix("POST /logs"),
              let separatorRange = request.range(of: "\r\n\r\n") else {
            return httpResponse(status: "404 Not Found", body: "Not found")
        }

        let body = String(request[separatorRange.upperBound...])
        guard let bodyData = body.data(using: .utf8) else {
            return httpResponse(status: "400 Bad Request", body: "Bad body")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let logs = try decoder.decode([HourlyHandLog].self, from: bodyData)
            let acceptedIDs = store.importHourlyLogs(logs)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let responseData = try encoder.encode(SyncResponse(acceptedIDs: acceptedIDs))
            return httpResponse(status: "200 OK", body: responseData)
        } catch {
            return httpResponse(status: "400 Bad Request", body: "Invalid logs: \(error.localizedDescription)")
        }
    }

    private func httpResponse(status: String, body: String) -> Data {
        httpResponse(status: status, body: Data(body.utf8))
    }

    private func httpResponse(status: String, body: Data) -> Data {
        var response = Data()
        response.append(Data("HTTP/1.1 \(status)\r\n".utf8))
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        return response
    }
}
#endif
