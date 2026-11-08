import Foundation
import Combine
import UIKit
import Speech
import AVFAudio
import FoundationModels

// Deliberately closed schema: no arbitrary messages, paths, content or device IDs.
enum DiagnosticStatus: String, Codable {
    case pass, fail, unavailable
    case notRun = "not_run"
}
struct DiagnosticResults: Codable {
    var storage: DiagnosticStatus = .notRun
    var serialization: DiagnosticStatus = .notRun
    var backup: DiagnosticStatus = .notRun
    var credentialFilter: DiagnosticStatus = .notRun
    var modelAvailability: DiagnosticStatus = .notRun
    var modelGeneration: DiagnosticStatus = .notRun
    var speechAvailability: DiagnosticStatus = .notRun
    var onDeviceSpeech: DiagnosticStatus = .notRun
    var speechPermission: DiagnosticStatus = .notRun
    var microphonePermission: DiagnosticStatus = .notRun
    // Never contact a repository, start a microphone or simulate an upload.
    var recording: DiagnosticStatus = .notRun
    var repositoryUpload: DiagnosticStatus = .notRun
}
struct DiagnosticReport: Codable {
    var schemaVersion = 1
    var appVersion: String
    var iosVersion: String
    var checks = DiagnosticResults()
}

enum DiagnosticChecks {
    static func isDue(lastRun: Date?, now: Date) -> Bool {
        guard let lastRun else { return true }
        let elapsed = now.timeIntervalSince(lastRun)
        return elapsed < 0 || elapsed >= 3 * 24 * 60 * 60
    }
    private static func sample() -> SavedState {
        SavedState(notes: [MemoryNote(project: "diagnostic/sample", text: "Synthetic test note", source: "diagnostic")], chats: [])
    }
    static func serialization() -> DiagnosticStatus {
        do {
            let state = sample()
            let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
            return decoded.notes == state.notes && decoded.chats.isEmpty && decoded.version == state.version ? .pass : .fail
        } catch { return .fail }
    }
    static func backup() -> DiagnosticStatus {
        do {
            let state = sample()
            let decoded = try MemoryBackup.decode(MemoryBackup.encode(state))
            guard decoded.notes == state.notes else { return .fail }
            var unsupported = state
            unsupported.version = 999
            do {
                _ = try MemoryBackup.decode(JSONEncoder().encode(unsupported))
                return .fail
            } catch { return .pass }
        } catch { return .fail }
    }
    static func credentialFilter() -> DiagnosticStatus {
        // Tests only the helper's known patterns. Does not read credentials/Keychain.
        MemorySearch.canSave("Synthetic ordinary note") &&
        !MemorySearch.canSave("password=synthetic-test-value") &&
        !MemorySearch.canSave("github_pat_synthetic-test-value") ? .pass : .fail
    }
    static func storage(in directory: URL) -> DiagnosticStatus {
        let scratch = directory.appendingPathComponent("diagnostic-probe-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let disk = DiskStore(root: scratch)
            let state = sample()
            try disk.save(state)
            let restored = try disk.load()
            let matches = restored.notes == state.notes && restored.chats.isEmpty
            // Cleanup must also succeed for a passing check.
            try FileManager.default.removeItem(at: scratch)
            return matches ? .pass : .fail
        } catch { return .fail }
    }
}

@MainActor final class DiagnosticsController: ObservableObject {
    @Published private(set) var reportURL: URL?
    @Published private(set) var status = "Diagnostics have not run. Reports stay on this device."
    @Published private(set) var isRunning = false
    private let reportDirectory: URL
    private let defaults: UserDefaults
    private let lastRunKey = "diagnostics.lastSuccessfulReport.v1"
    private var report: DiagnosticReport?

    init(reportDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.reportDirectory = reportDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.defaults = defaults
    }

    /// Call on foreground activation. iOS does not guarantee periodic execution.
    func runIfDue() {
        guard !isRunning, DiagnosticChecks.isDue(lastRun: defaults.object(forKey: lastRunKey) as? Date, now: Date()) else { return }
        runChecks()
    }

    func runChecks() {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        var next = DiagnosticReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            iosVersion: UIDevice.current.systemVersion)
        next.checks.storage = DiagnosticChecks.storage(in: reportDirectory)
        next.checks.serialization = DiagnosticChecks.serialization()
        next.checks.backup = DiagnosticChecks.backup()
        next.checks.credentialFilter = DiagnosticChecks.credentialFilter()
        if case .available = SystemLanguageModel.default.availability {
            next.checks.modelAvailability = .pass
        } else { next.checks.modelAvailability = .unavailable }
        // No recognition task, audio engine or authorization request is created.
        if let speech = SFSpeechRecognizer() {
            next.checks.speechAvailability = speech.isAvailable ? .pass : .unavailable
            next.checks.onDeviceSpeech = speech.supportsOnDeviceRecognition ? .pass : .unavailable
        } else {
            next.checks.speechAvailability = .unavailable
            next.checks.onDeviceSpeech = .unavailable
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: next.checks.speechPermission = .pass
        case .notDetermined: next.checks.speechPermission = .notRun
        default: next.checks.speechPermission = .unavailable
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: next.checks.microphonePermission = .pass
        case .undetermined: next.checks.microphonePermission = .notRun
        default: next.checks.microphonePermission = .unavailable
        }
        save(next, recordsBasicRun: true)
    }

    /// Explicit user-button test only. Never called by runIfDue or runChecks.
    func runModelCheck() async {
        guard !isRunning else { return }
        if report == nil { runChecks() }
        guard var next = report else { return }
        isRunning = true
        status = "Running optional on-device model check…"
        defer { isRunning = false }
        guard case .available = SystemLanguageModel.default.availability else {
            next.checks.modelAvailability = .unavailable
            next.checks.modelGeneration = .unavailable
            save(next, recordsBasicRun: false)
            return
        }
        next.checks.modelAvailability = .pass
        do {
            let session = LanguageModelSession(instructions: "This is a synthetic diagnostic. Reply with one short greeting.")
            _ = try await session.respond(to: "Say hello.")
            try Task.checkCancellation()
            next.checks.modelGeneration = .pass
        } catch { next.checks.modelGeneration = .fail }
        save(next, recordsBasicRun: false)
    }

    private func save(_ next: DiagnosticReport, recordsBasicRun: Bool) {
        report = next
        do {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            let url = reportDirectory.appendingPathComponent("diagnostics.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(next).write(to: url, options: [.atomic, .completeFileProtection])
            reportURL = url
            if recordsBasicRun { defaults.set(Date(), forKey: lastRunKey) }
            status = "Redacted diagnostic report ready. Review before sharing; nothing was uploaded."
        } catch {
            // Never expose an earlier file as if the latest report succeeded.
            reportURL = nil
            status = "Could not save the diagnostic report. Try again while the device is unlocked."
        }
    }
}
