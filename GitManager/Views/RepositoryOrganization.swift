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
    @Binding var draggedGroupID: UUID?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(isTargeted && draggedGroupID == nil ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .top) {
                if isTargeted && draggedGroupID == nil && before != nil {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
            .onDrop(of: [.plainText], delegate: RepositoryDropDelegate(
                model: model, groupID: groupID, before: before,
                draggedGroupID: $draggedGroupID, isTargeted: $isTargeted
            ))
    }
}

private struct RepositoryDropDelegate: DropDelegate {
    let model: AppModel
    let groupID: UUID?
    let before: String?
    @Binding var draggedGroupID: UUID?
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        draggedGroupID == nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = validateDrop(info: info)
        isTargeted = allowed
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info), let provider = info.itemProviders(for: [.plainText]).first,
              provider.canLoadObject(ofClass: NSString.self) else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, let payload = SidebarDragPayload(string: value),
                  case .repository = payload else { return }
            Task { @MainActor in model.dropSidebarItem(value, on: groupID, before: before) }
        }
        return true
    }
}

enum SidebarDragItemProvider {
    static func make(for payload: SidebarDragPayload) -> NSItemProvider {
        NSItemProvider(object: payload.string as NSString)
    }
}

extension View {
    func repositoryDropTarget(model: AppModel, groupID: UUID?, draggedGroupID: Binding<UUID?>, before: String? = nil) -> some View {
        modifier(RepositoryDropTarget(model: model, groupID: groupID, before: before, draggedGroupID: draggedGroupID))
    }
}
