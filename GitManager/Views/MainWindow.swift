import GitManagerCore
import SwiftUI
import AppKit

struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @State private var addingRemote = false
    @State private var pendingRemoval: RemovalConfirmation?

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
                        ForEach(records) { repo in
                            RepoRow(repo: repo, model: model, requestRemoval: requestRemoval).tag(repo.id)
                        }
                    } header: {
                        HStack {
                            Text(source.title)
                            if let issues = model.sourceScanErrors[source.id], !issues.isEmpty {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("Some folders could not be scanned")
                                    .help(issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
                            }
                        }
                            .help(localPath(source))
                            .contextMenu {
                                Button("Remove Source...", role: .destructive) { requestRemoval([source.id], false) }
                            }
                    }
                }
                ForEach(remoteHosts, id: \.self) { host in
                    Section(host) {
                        ForEach(model.visibleRepos.filter {
                            if case .remote(let remote) = $0.location.source { remote.host == host } else { false }
                        }) { repo in
                            RepoRow(repo: repo, model: model, requestRemoval: requestRemoval).tag(repo.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand {
                requestRemoval(model.selectedRemovalPlan.sourceIDs, model.selection.count > 1)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 420)
        } detail: {
            if let repo = model.selectedRepo {
                RepoDetail(repo: repo, model: model, requestRemoval: requestRemoval).id(repo.id)
            } else if model.selectedRepos.count > 1 {
                selectionSummary
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
        .sheet(isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            if let confirmation = pendingRemoval {
                RemovalConfirmationSheet(confirmation: confirmation, cancel: { pendingRemoval = nil },
                                         remove: { confirmRemoval(confirmation) })
            }
        }
        .alert("Git Manager", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } }
        )) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(model.selectedRepos.count) repositories selected").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.selectedRepos) { repo in
                        Text(repo.location.name).lineLimit(1).help(repo.location.displayPath)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            Button("Remove \(model.selectedRemovalPlan.entries.count) Sources...", role: .destructive) {
                requestRemoval(model.selectedRemovalPlan.sourceIDs, true)
            }
            .disabled(model.selectedRemovalPlan.entries.isEmpty)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Selection")
    }

    private func requestRemoval(_ sourceIDs: Set<UUID>, _ isBulk: Bool) {
        let plan = SourceRemovalPlan(sourceIDs: sourceIDs, sources: model.sources, repos: model.repos)
        guard !plan.entries.isEmpty else { return }
        pendingRemoval = RemovalConfirmation(plan: plan, isBulk: isBulk || plan.entries.count > 1)
    }

    private func confirmRemoval(_ confirmation: RemovalConfirmation) {
        // Validation and removal are synchronous on the main actor, so a rescan
        // cannot change membership between this check and the state update.
        switch confirmation.plan.confirmationDecision(sources: model.sources, repos: model.repos) {
        case .proceed(let current):
            pendingRemoval = nil
            model.removeSources(current.sourceIDs)
        case .reconfirm(let current):
            var updated = confirmation
            updated.plan = current
            updated.requiresReconfirmation = true
            pendingRemoval = updated
        case .noOp:
            pendingRemoval = nil
        }
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
