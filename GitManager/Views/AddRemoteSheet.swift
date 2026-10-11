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
    @State private var pathFocused = false
    @State private var listings: [ListingKey: [String]] = [:]
    @State private var highlighted = 0
    @State private var suggestionsHidden = false
    private let lister = RemoteDirectoryLister()

    /// One remote directory listing; suggestions are filtered locally while typing within it.
    private struct ListingKey: Hashable {
        let host: String
        let port: Int?
        let directory: String
    }

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
                LabeledContent("Repository path") {
                    let suggestions = suggestions
                    VStack(alignment: .leading, spacing: 4) {
                        CompletingTextField(text: $path, isFocused: $pathFocused,
                                            placeholder: "/home/user/project or ~/project", onKey: handleKey)
                        if !suggestionsHidden && pathFocused && !suggestions.isEmpty { suggestionList(suggestions) }
                    }
                }
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
        }
        .padding(24).frame(width: 480)
        // Only while editing the path, so typing the host does not connect to partial host names.
        .task(id: pathFocused ? listingKey : nil) { await loadListing() }
        .onChange(of: path) { highlighted = 0; suggestionsHidden = false }
    }

    private var listingKey: ListingKey? {
        guard let query = RemotePathCompletion.query(for: path) else { return nil }
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPort.isEmpty || Int(trimmedPort) != nil else { return nil }
        return ListingKey(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(trimmedPort),
                          directory: query.directory)
    }

    private var suggestions: [String] {
        guard let key = listingKey, let names = listings[key], let query = RemotePathCompletion.query(for: path) else { return [] }
        return Array(RemotePathCompletion.matches(names, prefix: query.prefix).prefix(200))
    }

    private func suggestionList(_ suggestions: [String]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { index, name in
                        Button { accept(name) } label: {
                            Label(name, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .foregroundStyle(index == highlighted ? Color.white : Color.primary)
                                .background(index == highlighted ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).id(name)
                    }
                }.padding(4)
            }
            .frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .onChange(of: highlighted) { if suggestions.indices.contains(highlighted) { proxy.scrollTo(suggestions[highlighted]) } }
        }
    }

    private func handleKey(_ key: CompletingTextField.Key) -> Bool {
        let current = suggestions
        guard !suggestionsHidden, !current.isEmpty else { return false }
        switch key {
        case .tab: accept(current[min(highlighted, current.count - 1)])
        case .down: highlighted = min(highlighted + 1, current.count - 1)
        case .up: highlighted = max(highlighted - 1, 0)
        case .escape: suggestionsHidden = true
        }
        return true
    }

    private func accept(_ name: String) {
        guard let query = RemotePathCompletion.query(for: path) else { return }
        path = RemotePathCompletion.completing(query, with: name)
    }

    private func loadListing() async {
        guard pathFocused, let key = listingKey, listings[key] == nil else { return }
        // Wait for typing to pause before connecting; a newer key cancels this task.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled,
              let names = await lister.folders(host: key.host, port: key.port, directory: key.directory) else { return }
        listings[key] = names
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
