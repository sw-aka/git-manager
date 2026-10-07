import GitManagerCore
import SwiftUI
import AppKit

struct MenuBarView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.syncRepos.isEmpty { Text("No repositories need sync") }
        ForEach(model.syncRepos) { repo in
            Menu("\(repo.location.name)  \(repo.status.badge)") {
                Text(repo.location.displayPath)
                Button("Sync") { Task { await model.sync(repo.id) } }
                    .disabled(model.busy.contains(repo.id) || !repo.status.canSync)
                Button("Open in Zed") { Task { await model.openInZed(repo.id) } }
                if let error = repo.status.error { Text(error) }
            }
        }
        Divider()
        Button(model.isRefreshing ? "Refreshing…" : "Refresh All") { Task { await model.refreshAll() } }
            .disabled(model.isRefreshing)
        Button("Open Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Git Manager") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
