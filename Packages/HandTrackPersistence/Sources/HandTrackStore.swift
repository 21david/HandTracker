import Foundation
import Combine
#if os(macOS)
import AppKit
#endif

@MainActor
final class HandTrackStore: ObservableObject {
    @Published private(set) var hourlyLogs: [HourlyHandLog] = []
    @Published private(set) var keystrokeEvents: [KeystrokeEvent] = []

    let storageDirectory: URL

    private let logsURL: URL
    private let keystrokesURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(storageDirectory: URL? = nil) {
        let baseDirectory = storageDirectory ?? Self.defaultStorageDirectory()
        self.storageDirectory = baseDirectory
        self.logsURL = baseDirectory.appendingPathComponent("hourly_logs.json")
        self.keystrokesURL = baseDirectory.appendingPathComponent("keystrokes.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        load()
    }

    func saveHourlyLog(painLevel: Int, minutesHandsUsed: Int, journalEntry: String) {
        let now = Date()
        let log = HourlyHandLog(
            hourStart: now.startOfHour,
            painLevel: painLevel,
            minutesHandsUsed: minutesHandsUsed,
            journalEntry: journalEntry,
            createdAt: now,
            updatedAt: now,
            syncStatus: .pending
        )
        hourlyLogs.insert(log, at: 0)
        persistLogs()
    }

    func importHourlyLogs(_ incomingLogs: [HourlyHandLog]) -> [UUID] {
        var acceptedIDs: [UUID] = []

        for var incoming in incomingLogs {
            incoming.syncStatus = .synced
            if let index = hourlyLogs.firstIndex(where: { $0.id == incoming.id }) {
                if incoming.updatedAt >= hourlyLogs[index].updatedAt {
                    hourlyLogs[index] = incoming
                }
            } else {
                hourlyLogs.append(incoming)
            }
            acceptedIDs.append(incoming.id)
        }

        hourlyLogs.sort { $0.hourStart > $1.hourStart }
        persistLogs()
        return acceptedIDs
    }

    func markLogsSynced(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for index in hourlyLogs.indices where ids.contains(hourlyLogs[index].id) {
            hourlyLogs[index].syncStatus = .synced
            hourlyLogs[index].updatedAt = Date()
        }
        persistLogs()
    }

    func pendingLogs() -> [HourlyHandLog] {
        hourlyLogs.filter { $0.syncStatus == .pending }
    }

    func recordKeystroke(at timestamp: Date = Date()) {
        keystrokeEvents.append(KeystrokeEvent(timestamp: timestamp))
        persistKeystrokes()
    }

    func keysSinceStartOfCurrentHour() -> Int {
        let hourStart = Date().startOfHour
        return keystrokeEvents.filter { $0.timestamp >= hourStart }.count
    }

    func averageWordsPerMinuteForCurrentHour() -> Double {
        let hourStart = Date().startOfHour
        let elapsedMinutes = max(Date().timeIntervalSince(hourStart) / 60, 1)
        let words = Double(keysSinceStartOfCurrentHour()) / 5
        return words / elapsedMinutes
    }

    func openStorageDirectory() {
        #if os(macOS)
        NSWorkspace.shared.open(storageDirectory)
        #endif
    }

    func reloadFromDisk() {
        load()
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            hourlyLogs = try loadArray(from: logsURL)
            keystrokeEvents = try loadArray(from: keystrokesURL)
        } catch {
            hourlyLogs = []
            keystrokeEvents = []
            print("Failed to load HandTrack data: \(error)")
        }
    }

    private func persistLogs() {
        persist(hourlyLogs, to: logsURL)
    }

    private func persistKeystrokes() {
        persist(keystrokeEvents, to: keystrokesURL)
    }

    private func loadArray<T: Decodable>(from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try decoder.decode([T].self, from: data)
    }

    private func persist<T: Encodable>(_ values: [T], to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(values)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to persist HandTrack data: \(error)")
        }
    }

    private static func defaultStorageDirectory() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL.appendingPathComponent("HandTrack", isDirectory: true)
    }
}
