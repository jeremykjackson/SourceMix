import AppKit
import OSLog
import UniformTypeIdentifiers

/// Collects SourceMix's own log messages plus a snapshot of the audio state and
/// saves them as a text file the user can share.
@MainActor
enum Diagnostics {
    static func export() {
        let snapshot = MixerStore.shared.diagnosticsSnapshot()
        let logText = recentLogs()
        let report = """
        ===== SourceMix diagnostics =====
        \(snapshot)

        ===== Log (this launch, last 60 minutes) =====
        \(logText)
        """

        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "SourceMix-Diagnostics-\(timestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private static func recentLogs() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-3600))
            let predicate = NSPredicate(format: "subsystem == %@", "com.jeremyjackson.SourceMix")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            let lines = try store.getEntries(at: start, matching: predicate).compactMap { entry -> String? in
                guard let log = entry as? OSLogEntryLog else { return nil }
                let level: String
                switch log.level {
                case .error: level = "ERROR"
                case .fault: level = "FAULT"
                case .notice: level = "note"
                case .info: level = "info"
                case .debug: level = "debug"
                default: level = "-"
                }
                return "\(formatter.string(from: log.date)) [\(level)] \(log.category): \(log.composedMessage)"
            }
            return lines.isEmpty ? "(no log entries)" : lines.suffix(3000).joined(separator: "\n")
        } catch {
            return "(could not read log: \(error.localizedDescription))"
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }
}
