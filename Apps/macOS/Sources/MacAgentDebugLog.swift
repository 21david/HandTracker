import Foundation

enum MacAgentDebugLog {
    private static let path = "/Users/david1/Documents/Code/Cursor/HandTrack/.cursor/debug-b2bfc5.log"
    private static let sessionId = "b2bfc5"
    private static let queue = DispatchQueue(label: "HandTrack.macAgentDebugLog")
    private static var contentBodyEvalCount = 0
    private static var lastContentBodyLogAt: CFAbsoluteTime = 0

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:]
    ) {
        // #region agent log
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        if !data.isEmpty { payload["data"] = data }
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8)
        else { return }
        let path = Self.path
        queue.async {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let bytes = (line + "\n").data(using: .utf8) {
                try? handle.write(contentsOf: bytes)
            }
        }
        // #endregion
    }

    /// Rate-limited counter for MacContentView body evaluations (main-thread safe enough for debug).
    static func noteContentBodyEval() {
        contentBodyEvalCount += 1
        let n = contentBodyEvalCount
        let now = CFAbsoluteTimeGetCurrent()
        guard n <= 5 || n % 25 == 0 || now - lastContentBodyLogAt >= 1.0 else { return }
        lastContentBodyLogAt = now
        log(
            hypothesisId: "P2",
            location: "MacContentView.swift:body",
            message: "content_body_eval",
            data: ["runId": "perf-coalesce", "n": n]
        )
    }
}
