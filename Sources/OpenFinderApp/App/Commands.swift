import SwiftUI

struct OpenFinderCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandMenu("File") {
            Button("New File") { app.activeBrowser.createFile() }
                .keyboardShortcut("n")
            Button("New Folder") { app.activeBrowser.createFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Refresh") { Task { await app.activeBrowser.refresh() } }
                .keyboardShortcut("r")
            Button("Parent Directory") { app.activeBrowser.goUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command])
            Divider()
            Button(app.activeBrowser.hasRemoteSelection ? "Delete…" : "Move to Trash") { app.activeBrowser.trashSelected() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        CommandMenu("Navigate") {
            Button("Back") { app.activeBrowser.goBack() }
                .keyboardShortcut("[", modifiers: [.command])
            Button("Forward") { app.activeBrowser.goForward() }
                .keyboardShortcut("]", modifiers: [.command])
            Button("Show Hidden Files") { app.activeBrowser.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
        }
        CommandMenu("Actions") {
            Button("Copy to Other Pane") { app.copySelectionToOtherPane(move: false) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Move to Other Pane") { app.copySelectionToOtherPane(move: true) }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Reveal in Finder") { app.revealSelectedInFinder() }
            Button("Open in Terminal") { app.openSelectedInTerminal() }
            Button("Quick Look") { app.quickLookSelected() }
                .keyboardShortcut(.space, modifiers: [])
        }
    }
}
