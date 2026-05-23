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
            listener.service = NWListener.Service(name: "Hand Helper Mac", type: "_handtrack._tcp")
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
        receiveCompleteRequest(on: connection, accumulated: Data())
    }

    /// Reads until headers + optional body are fully buffered. A single TCP `receive` is not enough —
    /// the POST body commonly arrives after the headers, otherwise JSON decode fails and we return 400;
    /// incomplete headers yield 404, and the iOS client reports `URLError(.badServerResponse)` (-1011).
    private func receiveCompleteRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 655_536) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    connection.cancel()
                    return
                }
                var buf = accumulated
                if let chunk, !chunk.isEmpty { buf.append(chunk) }

                if buf.count > 8 * 1024 * 1024 {
                    connection.cancel()
                    return
                }

                guard let requestData = Self.extractCompleteHTTPRequest(buf, streamComplete: isComplete) else {
                    if isComplete {
                        connection.cancel()
                    } else {
                        self.receiveCompleteRequest(on: connection, accumulated: buf)
                    }
                    return
                }

                let response = self.response(for: requestData)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private static let headerBodySeparator = Data("\r\n\r\n".utf8)

    private static func extractCompleteHTTPRequest(_ data: Data, streamComplete: Bool) -> Data? {
        guard let sepRange = data.range(of: headerBodySeparator) else { return nil }
        let headersData = data.subdata(in: data.startIndex ..< sepRange.lowerBound)
        guard let headers = String(data: headersData, encoding: .utf8) else { return nil }
        let bodyStart = sepRange.upperBound

        let firstLine = headers.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let isPOST = firstLine.uppercased().hasPrefix("POST ")

        if let contentLength = parseContentLength(headers) {
            guard data.count >= bodyStart + contentLength else { return nil }
            return data.prefix(bodyStart + contentLength)
        }

        if isPOST, streamComplete {
            return data
        }

        if isPOST {
            return nil
        }

        return data.prefix(bodyStart)
    }

    private static func parseContentLength(_ headers: String) -> Int? {
        for line in headers.split(separator: "\r\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.lowercased() == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }
        return nil
    }

    private func response(for requestData: Data) -> Data {
        guard let separatorRange = requestData.range(of: Self.headerBodySeparator) else {
            return httpResponse(status: "400 Bad Request", body: "Missing headers")
        }

        let headersData = requestData.subdata(in: requestData.startIndex..<separatorRange.lowerBound)
        guard let headers = String(data: headersData, encoding: .utf8) else {
            return httpResponse(status: "400 Bad Request", body: "Invalid headers")
        }

        let firstLine = headers.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        print("Sync server received: \(firstLine)")

        if firstLine.hasPrefix("GET /health") {
            return httpResponse(status: "200 OK", body: #"{"status":"ok"}"#)
        }

        guard firstLine.hasPrefix("POST /logs") else {
            return httpResponse(status: "404 Not Found", body: "Not found")
        }

        let bodyData = requestData.subdata(in: separatorRange.upperBound..<requestData.endIndex)
        if bodyData.isEmpty {
            return httpResponse(status: "400 Bad Request", body: "Empty body")
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let logs = try decoder.decode([HourlyHandLog].self, from: bodyData)
            print("Sync server importing \(logs.count) logs")
            let acceptedIDs = store.importHourlyLogs(logs)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let responseData = try encoder.encode(SyncResponse(acceptedIDs: acceptedIDs))
            return httpResponse(status: "200 OK", body: responseData)
        } catch {
            print("Sync server error decoding logs: \(error)")
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
