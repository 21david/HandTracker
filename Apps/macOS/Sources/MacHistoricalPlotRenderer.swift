import AppKit
import Foundation

/// One selectable all-time histogram metric backed by minute-bucket SQLite tables.
enum MacHistoricalPlotMetric: String, CaseIterable, Identifiable {
    case keystrokes
    case mouseClicks
    case mouseTravel
    case scrollBumps
    case builtinKeys
    case builtinTrackpadClicks
    case builtinTrackpadTravel
    case builtinTrackpadScroll

    var id: String { rawValue }

    /// Argument passed to `plot_metric_histogram.py --metric`.
    var pythonKey: String {
        switch self {
        case .keystrokes: return "keystrokes"
        case .mouseClicks: return "mouse_clicks"
        case .mouseTravel: return "mouse_travel"
        case .scrollBumps: return "scroll_bumps"
        case .builtinKeys: return "builtin_keys"
        case .builtinTrackpadClicks: return "builtin_trackpad_clicks"
        case .builtinTrackpadTravel: return "builtin_trackpad_travel"
        case .builtinTrackpadScroll: return "builtin_trackpad_scroll"
        }
    }

    var menuTitle: String {
        switch self {
        case .keystrokes: return "External keys / minute"
        case .mouseClicks: return "External clicks / minute"
        case .mouseTravel: return "Pointer travel / minute"
        case .scrollBumps: return "Scroll bumps / minute"
        case .builtinKeys: return "MacBook keys / minute"
        case .builtinTrackpadClicks: return "Trackpad clicks / minute"
        case .builtinTrackpadTravel: return "Trackpad travel / minute"
        case .builtinTrackpadScroll: return "Trackpad scroll / minute"
        }
    }
}

enum MacHistoricalPlotEngine: String, CaseIterable, Identifiable {
    case seaborn
    case plotly

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .seaborn: return "Seaborn (static)"
        case .plotly: return "Plotly (interactive)"
        }
    }

    var fileExtension: String {
        switch self {
        case .seaborn: return "png"
        case .plotly: return "html"
        }
    }
}

/// Runs the bundled pandas/seaborn/plotly script against HandTrack’s SQLite file.
@MainActor
enum MacHistoricalPlotRenderer {
    enum RenderError: LocalizedError {
        case missingScript
        case missingDatabase(URL)
        case pythonFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingScript:
                return "Plot script was not found in the app bundle."
            case .missingDatabase(let url):
                return "Database missing at \(url.path)."
            case .pythonFailed(let message):
                return message
            }
        }
    }

    static func render(
        metric: MacHistoricalPlotMetric,
        engine: MacHistoricalPlotEngine,
        databaseURL: URL,
        force: Bool = false
    ) async throws -> URL {
        let scriptURL = try resolveScriptURL()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw RenderError.missingDatabase(databaseURL)
        }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let outDir = cacheDir.appendingPathComponent("HandTrackPlots", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let dbStamp = (try? databaseURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? 0
        // Bump cache key when binning/layout changes so old PNGs aren't reused.
        let layoutStamp = "v5"
        let outURL = outDir.appendingPathComponent(
            "\(metric.pythonKey)-\(engine.rawValue)-\(layoutStamp)-\(Int(dbStamp)).\(engine.fileExtension)"
        )
        if !force, FileManager.default.fileExists(atPath: outURL.path) {
            return outURL
        }

        // Drop older cached renders for this metric+engine (and untagged legacy caches).
        let prefix = "\(metric.pythonKey)-\(engine.rawValue)-"
        if let existing = try? FileManager.default.contentsOfDirectory(
            at: outDir,
            includingPropertiesForKeys: nil
        ) {
            for url in existing {
                let name = url.lastPathComponent
                let isEngineCache = name.hasPrefix(prefix)
                let isLegacy = name.hasPrefix("\(metric.pythonKey)-")
                    && !name.contains("-seaborn-")
                    && !name.contains("-plotly-")
                if isEngineCache || isLegacy {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        let python = resolvePythonExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [
            scriptURL.path,
            "--db", databaseURL.path,
            "--metric", metric.pythonKey,
            "--engine", engine.rawValue,
            "--out", outURL.path,
        ]
        let stderr = Pipe()
        let stdout = Pipe()
        process.standardError = stderr
        process.standardOutput = stdout

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: RenderError.pythonFailed(
                            errText?.isEmpty == false
                                ? errText!
                                : "Python exited with status \(proc.terminationStatus)."
                        )
                    )
                }
            }
        }

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            throw RenderError.pythonFailed("Plot output was not written.")
        }
        return outURL
    }

    private static func resolveScriptURL() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "plot_metric_histogram", withExtension: "py") {
            return bundled
        }
        // Dev fallback: repo Resources path when running from DerivedData without a fresh copy.
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/plot_metric_histogram.py"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw RenderError.missingScript
    }

    private static func resolvePythonExecutable() -> String {
        let candidates = [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "python3"
    }
}
