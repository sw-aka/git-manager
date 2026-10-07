import GitManagerCore
import SwiftUI
import AppKit

struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @State private var addingRemote = false

    private var localSources: [RepoSource] {
        model.sources.filter { if case .local = $0 { true } else { false } }
    }
    private var remoteHosts: [String] {
        Set(model.sources.compactMap { if case .remote(let source) = $0 { source.host } else { nil } }).sorted()
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Button {
                    model.needsAttentionOnly = false
                } label: {
                    Label("All (\(model.repos.count))", systemImage: "tray.full")
                        .foregroundStyle(model.needsAttentionOnly ? Color.secondary : Color.accentColor)
                }.buttonStyle(.plain)
                Button {
                    model.needsAttentionOnly = true
                } label: {
                    Label("Needs attention (\(model.repos.filter { $0.status.needsAttention }.count))", systemImage: "exclamationmark.circle")
                        .foregroundStyle(model.needsAttentionOnly ? Color.accentColor : Color.secondary)
                }.buttonStyle(.plain)

                ForEach(localSources) { source in
                    Section {
                        let records = model.visibleRepos.filter { $0.location.source.id == source.id }
                        if records.isEmpty {
                            let shared = model.visibleRepos.contains { $0.sourceIDs.contains(source.id) }
                            Text(shared ? "Repositories listed under another source"
                                 : model.needsAttentionOnly ? "No repositories need attention" : "No repositories found")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(records) { repo in RepoRow(repo: repo, model: model).tag(repo.id) }
                    } header: {
                        Text(source.title)
                            .help(localPath(source))
                            .contextMenu {
                                Button("Remove Source", role: .destructive) { model.removeSource(source.id) }
                            }
                    }
                }
                ForEach(remoteHosts, id: \.self) { host in
                    Section(host) {
                        ForEach(model.visibleRepos.filter {
                            if case .remote(let remote) = $0.location.source { remote.host == host } else { false }
                        }) { repo in RepoRow(repo: repo, model: model).tag(repo.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 520)
        } detail: {
            if let repo = model.selectedRepo {
                RepoDetail(repo: repo, model: model)
            } else {
                ContentUnavailableView {
                    Label("Git Manager", systemImage: "arrow.triangle.branch")
                } description: {
                    Text(model.sources.isEmpty
                         ? "Add a local folder or a remote repository to start watching Git."
                         : "Select a repository to view its recent commits.")
                } actions: {
                    Button("Add Local Folder", action: addLocal)
                    Button("Add Remote Repo") { addingRemote = true }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add Local Folder", systemImage: "folder.badge.plus", action: addLocal)
                Button("Add Remote Repo", systemImage: "network") { addingRemote = true }
                Button { Task { await model.refreshAll() } } label: {
                    Label(model.isRefreshing ? "Refreshing…" : "Refresh All", systemImage: "arrow.clockwise")
                }.disabled(model.isRefreshing)
            }
        }
        .onAppear {
            #if DEBUG
            AppWindows.startLifecycleTest(using: openWindow)
            #endif
        }
        .sheet(isPresented: $addingRemote) { AddRemoteSheet(model: model) }
        .alert("Git Manager", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private func localPath(_ source: RepoSource) -> String {
        if case .local(let folder) = source { folder.path } else { "" }
    }
    private func addLocal() {
        let panel = NSOpenPanel()
        panel.title = "Add Local Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { panel.urls.forEach(model.addLocal) }
    }
}
