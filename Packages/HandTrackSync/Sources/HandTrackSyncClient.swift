import Foundation

enum HandTrackSyncClient {
    static func send(logs: [HourlyHandLog], to host: String) async throws -> SyncResponse {
        let normalizedHost = Self.normalizeUserHost(host)
        guard !normalizedHost.isEmpty else {
            throw URLError(.badURL)
        }

        let hostInURL = Self.bracketIPv6HostIfNeeded(normalizedHost)
        guard let url = URL(string: "http://\(hostInURL):8787/logs") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let encoder = JSONEncoder()
        // Match server JSON: fractional-second ISO8601 from encoders often fails `decoder.dateStrategy = .iso8601`.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        request.httpBody = try encoder.encode(logs)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.cannotParseResponse.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "No HTTP response from \(hostInURL):8787 — wrong IP, blocked by firewall, or another app is using that port (not Hand Helper on the Mac)."
                ]
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let snippet =
                String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240) ?? ""
            let extra = snippet.isEmpty ? "" : " — \(snippet)"
            throw NSError(
                domain: NSURLErrorDomain,
                code: URLError.badServerResponse.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: "Mac returned HTTP \(httpResponse.statusCode)\(extra)"
                ]
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(SyncResponse.self, from: data)
    }

    /// Strips schemes, stray slashes, and a trailing `:8787` so pasting `http://10.0.0.3:8787` does not become `:8787:8787`.
    private static func normalizeUserHost(_ raw: String) -> String {
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "https://", with: "", options: .caseInsensitive)
        while s.hasSuffix("/") {
            s.removeLast()
        }
        if s.lowercased().hasSuffix(":8787") {
            s = String(s.dropLast(":8787".count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Brackets IPv6 literals so `URL` is valid (`http://[fe80::1]:8787`).
    private static func bracketIPv6HostIfNeeded(_ host: String) -> String {
        if host.hasPrefix("[") { return host }
        if host.contains(":") { return "[\(host)]" }
        return host
    }
}
