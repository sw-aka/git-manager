import SwiftUI

struct AddRemoteSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Remote Repo").font(.title2.bold())
            Form {
                TextField("SSH host", text: $host, prompt: Text("alias or user@host"))
                TextField("Port (optional)", text: $port, prompt: Text("22"))
                TextField("Absolute path", text: $path, prompt: Text("/home/user/project"))
            }
            Text("Uses your existing SSH configuration and agent. Each remote repository is added individually.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }

    private func add() {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPort.isEmpty && Int(trimmedPort) == nil {
            error = "Port must be a number between 1 and 65535."
            return
        }
        let source = RemoteRepoSource(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                      port: Int(trimmedPort), path: path)
        do { try model.addRemote(source); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
