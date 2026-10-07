import Foundation
import GitManagerCore

struct RemovalConfirmation {
    let plan: SourceRemovalPlan
    let isBulk: Bool

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
            var lines = plan.entries.prefix(10).map { entry in
                let source: String
                switch entry.source {
                case .local(let folder): source = "Folder \(folder.path)"
                case .remote(let remote):
                    let name = URL(fileURLWithPath: remote.path).lastPathComponent
                    source = "\(name) (\(remote.host):\(remote.path))"
                        + (remote.port.map { " [port \($0)]" } ?? "")
                }
                return "• \(source): \(entry.repositoryCount) repositories"
            }
            if plan.entries.count > 10 { lines.append("and \(plan.entries.count - 10) more") }
            prompt = "Remove \(plan.entries.count) sources (\(plan.repositoryCount) repositories)?\n\n"
                + lines.joined(separator: "\n")
        }
        let retained = plan.retainedRepositoryCount > 0
            ? "\n\(plan.retainedRepositoryCount) repositories will stay in Git Manager because another source provides them."
            : ""
        return prompt + retained + "\n\nFiles on disk are not changed."
    }
}
