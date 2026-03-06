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
        // Write HTML body to a temp file — env vars are limited in size and AppleScript's
        // `system attribute` silently returns empty when the value is too large.
        let bodyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("html")
        try htmlBody.write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let script = upsertScript()
        try await runScript(script, env: [
            "NOTE_TITLE":      noteTitle,
            "NOTE_BODY_PATH":  bodyURL.path
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
        set bodyPath to system attribute "NOTE_BODY_PATH"
        set noteContent to read POSIX file bodyPath as «class utf8»

        tell application "Notes"
            if not (exists folder "Kindle Highlights") then
                make new folder with properties {name:"Kindle Highlights"}
            end if
            set targetFolder to folder "Kindle Highlights"
            -- Search all notes (not just the folder) so we find the note regardless
            -- of which account's folder it landed in on first creation.
            set matchingNotes to (every note whose name is noteName)
            if (count of matchingNotes) > 0 then
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
