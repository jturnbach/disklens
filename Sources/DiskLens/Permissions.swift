import Foundation
import AppKit

// macOS doesn't expose a TCC API for "is this app granted X". The standard
// trick is to probe a file that is *only* readable with Full Disk Access:
// the live TCC database itself. If we can stat it, FDA is on; otherwise we
// either don't have it or it hasn't been requested yet.
enum Permissions {
    static func hasFullDiskAccess() -> Bool {
        let testPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        return FileManager.default.isReadableFile(atPath: testPath)
    }

    // Opens System Settings → Privacy & Security → Full Disk Access.
    // The URL scheme has been stable from Catalina onward.
    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
