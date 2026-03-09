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

    static func upsert(noteTitle: String, htmlBody: String, coverImagePath: URL? = nil) async throws {
        // Write HTML body to a temp file — env vars are limited in size and AppleScript's
        // `system attribute` silently returns empty when the value is too large.
        let bodyURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("html")
        try htmlBody.write(to: bodyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let script = upsertScript()
        try await runScript(script, env: [
            "NOTE_TITLE":     noteTitle,
            "NOTE_BODY_PATH": bodyURL.path,
            "COVER_PATH":     coverImagePath?.path ?? ""
        ])
    }

    /// Deletes every note in the "Kindle Highlights" folder across all accounts.
    /// Used by the schema 18 migration to clear accumulated duplicates from prior
    /// migration runs before recreating all notes with the corrected title format.
    static func clearKindleHighlightsFolder() async throws {
        let script = """
        tell application "Notes"
            repeat with searchAcct in accounts
                if (exists folder "Kindle Highlights" of searchAcct) then
                    set allNotes to every note of folder "Kindle Highlights" of searchAcct
                    repeat with n in allNotes
                        delete n
                    end repeat
                end if
            end repeat
        end tell
        """
        try await runScript(script, env: [:])
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
        set coverPath to system attribute "COVER_PATH"
        set noteContent to read POSIX file bodyPath as «class utf8»

        tell application "Notes"
            -- Search all accounts for an existing "Kindle Highlights" folder so notes
            -- created by older versions (without account qualification) are found in
            -- whatever account they landed in. If no folder exists anywhere, create one
            -- in account 1 (iCloud when enabled, On My Mac otherwise).
            set targetFolder to missing value
            repeat with searchAcct in accounts
                if (exists folder "Kindle Highlights" of searchAcct) then
                    set targetFolder to folder "Kindle Highlights" of searchAcct
                    exit repeat
                end if
            end repeat
            if targetFolder is missing value then
                make new folder at account 1 with properties {name:"Kindle Highlights"}
                set targetFolder to folder "Kindle Highlights" of account 1
            end if
            -- Scope search to the folder so we never match notes in Recently Deleted.
            -- Use a repeat loop instead of a "whose name is" filter: the whose clause
            -- mis-handles colons in note names (AppleScript treats ":" as a path separator
            -- in object specifier filters), silently returning empty for titles like
            -- "Name: Subtitle by Author". A plain loop comparison works correctly.
            set matchingNotes to {}
            repeat with n in (every note of targetFolder)
                if name of n is noteName then
                    set matchingNotes to matchingNotes & {n}
                end if
            end repeat
            if (count of matchingNotes) > 0 then
                try
                    set body of (item 1 of matchingNotes) to noteContent
                    set theNote to item 1 of matchingNotes
                on error
                    -- set body failed (note has embedded objects or is otherwise immutable).
                    -- Delete all matches so ghost notes don't accumulate, then create fresh.
                    repeat with oldNote in matchingNotes
                        delete oldNote
                    end repeat
                    set theNote to make new note at targetFolder with properties {body:noteContent}
                end try
            else
                set theNote to make new note at targetFolder with properties {body:noteContent}
            end if
            -- Attach cover image via file reference. Notes reads the file directly;
            -- no data passes through Apple Events so file size is not a concern.
            -- Clear any stale attachments from previous syncs first so we never double-up.
            if coverPath is not "" then
                set existingAtts to (every attachment of theNote)
                repeat with att in existingAtts
                    delete att
                end repeat
                make new attachment with data (POSIX file coverPath) at theNote
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

        // Run in background thread to avoid blocking.
        // A serial queue + reference-type latch ensures the timeout and
        // terminationHandler never both resume the continuation — only the
        // first one through the `once.done` guard wins; the second is a no-op.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let q = DispatchQueue(label: "com.kindlesync.osascript")
            // `let` binding (not var) avoids Swift 6 captured-var mutation warning;
            // serial queue `q` guarantees exclusive access to `once.done`.
            final class Once { var done = false }
            let once = Once()

            let timeout = DispatchWorkItem {
                q.async {
                    guard !once.done else { return }
                    once.done = true
                    process.terminate()
                    continuation.resume(throwing: AppleNotesError.scriptFailed(
                        "osascript timed out after 30 s (Notes may be unresponsive)"))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)

            process.terminationHandler = { proc in
                q.async {
                    timeout.cancel()
                    guard !once.done else { return }
                    once.done = true
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
}
