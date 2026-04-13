import SwiftUI
import AppKit
import Quartz

// Wraps QLPreviewView so we can show a live QuickLook of the selected file.
// QLPreviewView handles images, videos, PDFs, text, and most common formats
// out of the box, including thumbnails for app bundles and folders.
struct QuickLookView: NSViewRepresentable {
    let url: URL?

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        v.autostarts = true
        v.shouldCloseWithWindow = false
        return v
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        // QuickLook hangs on remote/large files; we pass a URL only when it
        // is local and exists. Folders are handled separately.
        if let url = url, FileManager.default.fileExists(atPath: url.path) {
            view.previewItem = url as QLPreviewItem
        } else {
            view.previewItem = nil
        }
    }
}
