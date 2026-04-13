import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DiskLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DiskLens", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .onAppear { model.loadAISettings() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Folder…") { model.chooseAndScan() }
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .newItem) {
                Button("Scan Home Folder") {
                    model.startScan(url: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Move to Trash") { model.moveSelectionToTrash() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Button("Reveal in Finder") { model.revealSelectionInFinder() }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
    }
}
