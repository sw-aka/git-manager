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
                OpenInEditorMenu(repo: repo, model: model)
                if let error = repo.status.error { Text(error) }
            }
        }
        Divider()
        Button(model.isRefreshing ? "Refreshing…" : "Refresh All") { Task { await model.refreshAll() } }
            .disabled(model.isRefreshing)
        Button("Open Window") {
            AppWindows.openMain(using: openWindow)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Git Manager") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
