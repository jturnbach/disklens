import Foundation

// Shells out to osascript to run a shell command with administrator
// privileges. This is the standard macOS mechanism for desktop apps to
// elevate when they need to touch root-owned files — users see the normal
// system password prompt, and the operation runs under launchd's privileged
// helper. Cleaner than dealing with AuthorizationServices by hand.
enum AdminElevation {
    enum Result {
        case success
        case cancelled
        case failure(String)
    }

    // Moves a file or directory into the current user's ~/.Trash via
    // `sudo mv`, wrapped in an AppleScript "do shell script ... with
    // administrator privileges" invocation. Uses mv rather than rm so the
    // user can recover from Trash if they change their mind.
    static func moveToUserTrash(path: String, reason: String) -> Result {
        guard let home = ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectoryForUser(NSUserName()) else {
            return .failure("Could not locate home directory")
        }
        let trashDir = (home as NSString).appendingPathComponent(".Trash")
        // Ensure the target filename doesn't clash with an existing entry
        // in Trash — AppKit's normal trashItem appends "N" automatically,
        // but /bin/mv would overwrite. Append a timestamp if needed.
        let fm = FileManager.default
        let lastComponent = (path as NSString).lastPathComponent
        var dest = (trashDir as NSString).appendingPathComponent(lastComponent)
        if fm.fileExists(atPath: dest) {
            let stamp = Int(Date().timeIntervalSince1970)
            dest = (trashDir as NSString).appendingPathComponent(
                "\(lastComponent).\(stamp)")
        }

        let shellCmd = "/bin/mv \(shellQuote(path)) \(shellQuote(dest))"
        let script = """
        do shell script "\(appleScriptEscape(shellCmd))" \
        with prompt "DiskLens needs your password to \(appleScriptEscape(reason))." \
        with administrator privileges
        """
        return runOsascript(script)
    }

    static func runOsascript(_ script: String) -> Result {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        do {
            try task.run()
        } catch {
            return .failure(error.localizedDescription)
        }
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            return .success
        }
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // User-cancelled admin prompt → osascript exits with code 1 and a
        // "User canceled" message from Apple Events.
        if errMsg.contains("User canceled")
            || errMsg.contains("User cancelled")
            || errMsg.contains("-128") {
            return .cancelled
        }
        return .failure(errMsg.isEmpty ? "Unknown error" : errMsg)
    }

    // Shell-quotes a string for embedding inside a double-quoted
    // "do shell script" argument. Wraps in single quotes and escapes any
    // embedded single quotes using the standard `'\''` idiom.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // Escapes a string so it can be embedded inside a double-quoted
    // AppleScript string literal.
    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
