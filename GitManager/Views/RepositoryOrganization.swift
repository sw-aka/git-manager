import GitManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    var group: RepoGroup?
    var repositoryIDs: Set<String> = []
    var parentID: UUID?
}

struct GroupNameSheet: View {
    let model: AppModel
    let request: GroupEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(model: AppModel, request: GroupEditorRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: request.group?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.group != nil ? "Rename Group" : request.parentID != nil ? "New Subgroup" : "New Group").font(.headline)
            if request.group == nil, let parentID = request.parentID {
                Text("In: \(model.organization.path(of: parentID))").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Group name", text: $name).focused($nameFocused).onSubmit(save)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.group == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }

    private func save() {
        do {
            if let group = request.group {
                try model.renameGroup(group.id, to: name)
            } else {
                let id = try model.createGroup(named: name, parentID: request.parentID)
                model.moveRepositories(request.repositoryIDs, to: id)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Shared by row context menus and the multiple-selection detail view.
struct RepositoryGroupMenu: View {
    let model: AppModel
    let repositoryIDs: Set<String>
    let newGroup: (Set<String>) -> Void

    var body: some View {
        Menu("Move to Group") {
            ForEach(model.organization.outline()) { entry in
                let group = entry.group
                Button {
                    model.moveRepositories(repositoryIDs, to: group.id)
                } label: {
                    if allInGroup(group.id) { Label(model.organization.path(of: group.id), systemImage: "checkmark") }
                    else { Text(model.organization.path(of: group.id)) }
                }.disabled(allInGroup(group.id))
            }
            Button {
                model.moveRepositories(repositoryIDs, to: nil)
            } label: {
                if allInGroup(nil) { Label("Ungrouped", systemImage: "checkmark") }
                else { Text("Ungrouped") }
            }.disabled(allInGroup(nil))
            Divider()
            Button("New Group…") { newGroup(repositoryIDs) }
        }
    }

    private func allInGroup(_ id: UUID?) -> Bool {
        !repositoryIDs.isEmpty && repositoryIDs.allSatisfy { model.organization.groupByRepository[$0] == id }
    }
}

private struct RepositoryDropTarget: ViewModifier {
    let model: AppModel
    let groupID: UUID?
    var before: String?
    let dragState: SidebarDragState

    private var target: SidebarDropTarget { before.map { .repository($0) } ?? .emptyGroup(groupID) }
    private var isTargeted: Bool { dragState.target == target }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .top) {
                if isTargeted && before != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
            .onDrop(of: [.plainText], delegate: RepositoryDropDelegate(
                model: model, groupID: groupID, before: before,
                dragState: dragState, target: target
            ))
    }
}

private struct RepositoryDropDelegate: DropDelegate {
    let model: AppModel
    let groupID: UUID?
    let before: String?
    let dragState: SidebarDragState
    let target: SidebarDropTarget

    func validateDrop(info: DropInfo) -> Bool {
        dragState.acceptsRepositoryDrop(before: before) && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { updateTarget(info) }
    func dropExited(info: DropInfo) { dragState.leave(target) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = updateTarget(info)
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    @discardableResult
    private func updateTarget(_ info: DropInfo) -> Bool {
        let allowed = validateDrop(info: info)
        if allowed { dragState.hover(target) }
        else { dragState.clearTarget() }
        return allowed
    }

    func performDrop(info: DropInfo) -> Bool {
        dragState.clearTarget()
        guard validateDrop(info: info), let payload = dragState.payload else { return false }
        return model.dropSidebarItem(payload.string, on: groupID, before: before)
    }
}

extension View {
    func repositoryDropTarget(model: AppModel, groupID: UUID?, dragState: SidebarDragState, before: String? = nil) -> some View {
        modifier(RepositoryDropTarget(model: model, groupID: groupID, before: before, dragState: dragState))
    }
}
