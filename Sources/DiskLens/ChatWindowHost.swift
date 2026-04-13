import SwiftUI
import AppKit

// NSWindowController that hosts AIChatView when the user pops the chat out
// of the main window. We manage this ourselves instead of declaring a
// second SwiftUI Window scene so the close → chatPresentation = .hidden
// transition is synchronous and reliable.
@MainActor
final class ChatWindowHost: NSObject, NSWindowDelegate {
    private weak var model: AppModel?

    private static var activeHosts: [ChatWindowHost] = []

    static func popOut(model: AppModel) {
        // If the chat is already floating, just bring it forward.
        if let existing = model.floatingChatController?.window {
            existing.makeKeyAndOrderFront(nil)
            model.chatPresentation = .floating
            return
        }

        let host = ChatWindowHost()
        host.model = model

        let chatView = AIChatView().environmentObject(model)
        let hosting = NSHostingView(rootView: chatView)
        hosting.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "DiskLens Assistant"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 480)
        window.contentView = hosting
        window.center()
        window.delegate = host

        let controller = NSWindowController(window: window)
        model.floatingChatController = controller
        model.chatPresentation = .floating
        // Retain the host until the window closes.
        activeHosts.append(host)

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model = model else { return }
            model.floatingChatController = nil
            // If the user closed the floating window we go back to hidden,
            // not docked — closing is "I'm done for now." Toolbar Assistant
            // button will re-dock on next open.
            if model.chatPresentation == .floating {
                model.chatPresentation = .hidden
            }
            ChatWindowHost.activeHosts.removeAll { $0 === self }
        }
    }
}
