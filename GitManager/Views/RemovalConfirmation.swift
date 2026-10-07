import Foundation
import GitManagerCore
import SwiftUI

struct RemovalConfirmation {
    var plan: SourceRemovalPlan
    let isBulk: Bool
    var requiresReconfirmation = false

    var message: String {
        let prompt: String
        if !isBulk, let entry = plan.entries.first, plan.entries.count == 1 {
            switch entry.source {
            case .local(let folder):
                prompt = "Remove folder \(folder.path) and its \(entry.repositoryCount) repositories from Git Manager?"
            case .remote(let remote):
                let name = URL(fileURLWithPath: remote.path).lastPathComponent
                prompt = "Remove \(name) (\(remote.host):\(remote.path))?"
                    + (remote.port.map { "\nSSH port: \($0)." } ?? "")
            }
        } else {
            prompt = "Remove \(plan.entries.count) sources (\(plan.repositoryCount) repositories) from Git Manager?"
        }
        return prompt + " Files on disk are not changed."
    }
}

struct RemovalConfirmationSheet: View {
    let confirmation: RemovalConfirmation
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(confirmation.message).font(.headline)
            if confirmation.requiresReconfirmation {
                Text("The repositories changed while this was open. Please confirm again.")
                    .foregroundStyle(.secondary)
            }
            List(confirmation.plan.entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name(entry.source)).font(.body.weight(.semibold))
                        Text(path(entry.source)).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Text("\(entry.repositoryCount) repositories").font(.caption)
                        .fixedSize()
                }
                .padding(.vertical, 3)
            }
            .listStyle(.plain)
            if confirmation.plan.retainedRepositoryCount > 0 {
                Text("\(confirmation.plan.retainedRepositoryCount) repositories will stay in Git Manager because another source provides them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.defaultAction)
                Button("Remove", role: .destructive, action: remove)
            }
        }
        .padding(20)
        .frame(width: 540, height: 380)
        .onExitCommand(perform: cancel)
    }

    private func name(_ source: RepoSource) -> String {
        switch source {
        case .local: source.title
        case .remote(let remote): URL(fileURLWithPath: remote.path).lastPathComponent
        }
    }

    private func path(_ source: RepoSource) -> String {
        switch source {
        case .local(let folder): folder.path
        case .remote(let remote):
            "\(remote.host):\(remote.path)" + (remote.port.map { " [port \($0)]" } ?? "")
        }
    }
}
