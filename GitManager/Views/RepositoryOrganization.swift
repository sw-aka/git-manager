import GitManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct GroupEditorRequest: Identifiable {
    let id = UUID()
    var group: RepoGroup?
    var repositoryIDs: Set<String> = []
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
            Text(request.group == nil ? "New Group" : "Rename Group").font(.headline)
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
                let id = try model.createGroup(named: name)
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
            ForEach(model.organization.groups) { group in
                Button {
                    model.moveRepositories(repositoryIDs, to: group.id)
                } label: {
                    if allInGroup(group.id) { Label(group.name, systemImage: "checkmark") }
                    else { Text(group.name) }
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

enum RepositoryDrag {
    static let prefix = "gitmanager-repository:"
    static func value(for id: String) -> String { prefix + id }
}

private struct RepositoryDropTarget: ViewModifier {
    let model: AppModel
    let groupID: UUID?
    var before: String?
    @State private var isTargeted = false

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
            .onDrop(of: [.plainText], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let value = value as? String, value.hasPrefix(RepositoryDrag.prefix) else { return }
                    let id = String(value.dropFirst(RepositoryDrag.prefix.count))
                    Task { @MainActor in
                        model.moveRepositories([id], to: groupID, before: before)
                    }
                }
                return true
            }
    }
}

extension View {
    func repositoryDropTarget(model: AppModel, groupID: UUID?, before: String? = nil) -> some View {
        modifier(RepositoryDropTarget(model: model, groupID: groupID, before: before))
    }
}
