import GitManagerCore
import SwiftUI

struct AddRemoteSheet: View {
    let model: AppModel
    /// The source being edited; nil adds a new remote repository.
    let editing: RemoteRepoSource?
    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var port: String
    @State private var path: String
    @State private var error: String?

    init(model: AppModel, editing: RemoteRepoSource? = nil) {
        self.model = model
        self.editing = editing
        _host = State(initialValue: editing?.host ?? "")
        _port = State(initialValue: editing?.port.map(String.init) ?? "")
        _path = State(initialValue: editing?.path ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(editing == nil ? "Add Remote Repo" : "Edit Remote Repo").font(.title2.bold())
            Form {
                TextField("SSH host", text: $host, prompt: Text("alias or user@host"))
                TextField("Port (optional)", text: $port, prompt: Text("22"))
                TextField("Repository path", text: $path, prompt: Text("/home/user/project or ~/project"))
            }
            Text("Uses your existing SSH configuration and agent. Each remote repository is added individually.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }

    private func save() {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty && Int(trimmedPort) == nil {
            error = "Port must be a number between 1 and 65535."
            return
        }
        let source = RemoteRepoSource(id: editing?.id ?? UUID(), host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                      port: Int(trimmedPort), path: path)
        do {
            if editing == nil { try model.addRemote(source) } else { try model.updateRemote(source) }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
}
