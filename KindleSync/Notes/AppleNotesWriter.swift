import Foundation

enum AppleNotesError: Error, LocalizedError {
    case scriptFailed(String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let msg): return "AppleScript failed: \(msg)"
        case .permissionDenied: return "Notes automation permission denied."
        }
    }
}

struct AppleNotesWriter {

    // MARK: - Public API

    static func upsert(noteTitle: String, htmlBody: String) async throws {
        let script = upsertScript()
        try await runScript(script, env: [
            "NOTE_TITLE": noteTitle,
            "NOTE_BODY":  htmlBody
        ])
    }

    static func ensureNotesPermission() async -> Bool {
        let script = "tell application \"Notes\" to get name"
        do {
            try await runScript(script, env: [:])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Script Content

    private static func upsertScript() -> String {
        """
        set noteName to system attribute "NOTE_TITLE"
        set noteContent to system attribute "NOTE_BODY"

        tell application "Notes"
            if not (exists folder "Kindle Highlights") then
                make new folder with properties {name:"Kindle Highlights"}
            end if
            set targetFolder to folder "Kindle Highlights"
            set matchingNotes to (notes in targetFolder whose name is noteName)
            if length of matchingNotes > 0 then
                set body of (item 1 of matchingNotes) to noteContent
            else
                make new note at targetFolder with properties {name:noteName, body:noteContent}
            end if
        end tell
        """
    }

    // MARK: - Script Runner

    private static func runScript(_ script: String, env: [String: String]) async throws {
        // Write script to temp file
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("applescript")

        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        // Build process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [tempURL.path]

        // Merge env vars with current environment
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env {
            environment[key] = value
        }
        process.environment = environment

        // Capture stderr for error reporting
        let pipe = Pipe()
        process.standardError = pipe

        try process.run()

        // Run in background thread to avoid blocking
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
                    if errMsg.lowercased().contains("not authorized") || errMsg.lowercased().contains("permission") {
                        continuation.resume(throwing: AppleNotesError.permissionDenied)
                    } else {
                        continuation.resume(throwing: AppleNotesError.scriptFailed(errMsg))
                    }
                }
            }
        }
    }
}
