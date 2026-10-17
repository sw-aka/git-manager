import GitManagerCore
import SwiftUI
import AppKit

struct MainWindow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel
    @State private var addingRemote = false
    @State private var transferringSetup = false
    @State private var pendingRemoval: RemovalConfirmation?
    @State private var editingRemote: RemoteRepoSource?
    @State private var editingGroup: GroupEditorRequest?
    @State private var dragState = SidebarDragState()

    private var localSources: [RepoSource] {
        model.sources.filter { if case .local = $0 { true } else { false } }
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

                ForEach(sidebarItems) { item in
                    switch item {
                    case .group(let entry):
                        GroupHeaderRow(model: model, group: entry.group, depth: entry.depth,
                                       dragState: dragState, newSubgroup: newSubgroup,
                                       rename: { editingGroup = GroupEditorRequest(group: $0) })
                            .selectionDisabled()
                    case .ungrouped:
                        GroupHeaderRow(model: model, group: nil, depth: 0,
                                       dragState: dragState, newSubgroup: newSubgroup,
                                       rename: { editingGroup = GroupEditorRequest(group: $0) })
                            .selectionDisabled()
                    case .repository(let repo, let depth):
                        RepoRow(repo: repo, model: model, requestRemoval: requestRemoval, editSource: editSource,
                                newGroup: newGroup, dragState: dragState)
                            .padding(.leading, CGFloat(depth) * 16 + 24)
                            .contentShape(Rectangle())
                            .tag(repo.id)
                            .overlay {
                                SidebarDragSource(payload: .repository(repo.id), state: dragState,
                                                  preview: SidebarDragPreview(name: repo.location.name,
                                                      detail: repo.status.branch, symbol: "arrow.triangle.branch",
                                                      colorScheme: colorScheme),
                                                  select: { model.selection = [repo.id] })
                            }
                    case .empty(let groupID, let depth):
                        Text(model.needsAttentionOnly ? "No repositories need attention" : "Drag repositories here")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, CGFloat(depth) * 16 + 24)
                            .padding(.vertical, 4)
                            .repositoryDropTarget(model: model, groupID: groupID, dragState: dragState)
                            .selectionDisabled()
                    }
                }

                if !localSources.isEmpty {
                    Section("Source Folders") {
                        ForEach(localSources) { source in
                            HStack {
                                Label(source.title, systemImage: "folder")
                                Spacer()
                                Text("\(model.repos.filter { $0.sourceIDs.contains(source.id) }.count)")
                                    .foregroundStyle(.secondary)
                                if let issues = model.sourceScanErrors[source.id], !issues.isEmpty {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .accessibilityLabel("Some folders could not be scanned")
                                        .help(issues.map { "\($0.path): \($0.message)" }.joined(separator: "\n"))
                                }
                            }
                            .font(.caption)
                            .help(localPath(source))
                            .contextMenu {
                                Button("Change Folder...") { editSource(source.id) }
                                Button("Remove Source...", role: .destructive) { requestRemoval([source.id], false) }
                            }
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
                RepoDetail(repo: repo, model: model, requestRemoval: requestRemoval, editSource: editSource).id(repo.id)
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
                Button("Export / Import Setup", systemImage: "arrow.up.arrow.down") { transferringSetup = true }
                Button("New Group", systemImage: "rectangle.3.group") { newGroup([]) }
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
        .sheet(isPresented: $transferringSetup) { ConfigurationTransferView(model: model) }
        .sheet(isPresented: $addingRemote) { AddRemoteSheet(model: model) }
        .sheet(item: $editingRemote) { AddRemoteSheet(model: model, editing: $0) }
        .sheet(item: $editingGroup) { GroupNameSheet(model: model, request: $0) }
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

    private var sidebarItems: [RepositorySidebarItem] {
        var items: [RepositorySidebarItem] = []
        for entry in model.organization.outline(visibleOnly: true) {
            items.append(.group(entry))
            if entry.group.isExpanded {
                let records = model.repositories(in: entry.id)
                items.append(contentsOf: records.map { .repository($0, depth: entry.depth + 1) })
                if records.isEmpty && model.organization.children(of: entry.id).isEmpty {
                    items.append(.empty(groupID: entry.id, depth: entry.depth + 1))
                }
            }
        }
        items.append(.ungrouped)
        if model.organization.ungroupedExpanded {
            let records = model.repositories(in: nil)
            items.append(contentsOf: records.map { .repository($0, depth: 1) })
            if records.isEmpty { items.append(.empty(groupID: nil, depth: 1)) }
        }
        return items
    }

    private func newSubgroup(_ parentID: UUID) {
        editingGroup = GroupEditorRequest(parentID: parentID)
    }

    private func newGroup(_ repositoryIDs: Set<String>) {
        editingGroup = GroupEditorRequest(repositoryIDs: repositoryIDs)
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
            RepositoryGroupMenu(model: model, repositoryIDs: model.selection, newGroup: newGroup)
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
    private func editSource(_ sourceID: UUID) {
        switch model.sources.first(where: { $0.id == sourceID }) {
        case .remote(let remote): editingRemote = remote
        case .local(let folder): changeFolder(folder)
        case nil: break
        }
    }
    private func changeFolder(_ folder: LocalFolderSource) {
        let panel = NSOpenPanel()
        panel.title = "Change Folder"
        panel.message = "Choose a new folder to replace \(folder.path)."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: folder.path)
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.updateLocal(folder.id, to: url) }
        catch { model.message = error.localizedDescription }
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

private enum RepositorySidebarItem: Identifiable {
    case group(RepoGroupOutlineEntry)
    case ungrouped
    case repository(RepoRecord, depth: Int)
    case empty(groupID: UUID?, depth: Int)

    var id: String {
        switch self {
        case .group(let entry): "group:\(entry.id)"
        case .ungrouped: "ungrouped"
        case .repository(let repo, _): "repo:\(repo.id)"
        case .empty(let id, _): "empty:\(id?.uuidString ?? "ungrouped")"
        }
    }
}
