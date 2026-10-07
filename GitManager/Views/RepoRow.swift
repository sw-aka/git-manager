import GitManagerCore
import SwiftUI

struct RepoRow: View {
    let repo: RepoRecord
    let model: AppModel
    private var isBusy: Bool { model.busy.contains(repo.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(repo.location.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                if isBusy { ProgressView().controlSize(.small) }
                if let error = repo.status.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).help(error).accessibilityLabel("Repository error: \(error)")
                }
            }
            HStack(spacing: 8) {
                Label(repo.status.branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                Spacer(minLength: 0)
                if repo.status.upstream == nil || repo.status.upstreamGone || repo.status.needsSync {
                    Text(repo.status.badge)
                        .foregroundStyle(repo.status.upstream == nil || repo.status.upstreamGone ? .secondary : .primary)
                        .help(repo.status.upstream ?? "No upstream configured")
                }
                if repo.status.dirtyCount > 0 || repo.status.dirtyCountIsLowerBound {
                    HStack(spacing: 3) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text(repo.status.dirtyCountText)
                    }.help(repo.status.dirtyCountIsLowerBound
                           ? "At least \(repo.status.dirtyCount) changed files; status output was truncated"
                           : "\(repo.status.dirtyCount) changed files")
                }
            }.font(.caption)
            if let commit = repo.commits.first {
                Text(commit.subject).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                Text(RelativeTime.string(commit.date)).font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button("Sync", systemImage: "arrow.triangle.2.circlepath") { Task { await model.sync(repo.id) } }
                    .disabled(isBusy || !repo.status.canSync)
                    .help(repo.status.dirtyCountIsLowerBound ? "Sync is disabled because status output was truncated"
                          : repo.status.canSync ? "Fast-forward pull, then push" : "Sync requires a branch and an upstream or origin")
                Button("Open in Zed", systemImage: "arrow.up.right.square") { Task { await model.openInZed(repo.id) } }
                Spacer(minLength: 0)
                Button { Task { await model.refresh(repo.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isBusy).help("Fetch and refresh").accessibilityLabel("Refresh \(repo.location.name)")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Sync") { Task { await model.sync(repo.id) } }.disabled(isBusy || !repo.status.canSync)
            Button("Open in Zed") { Task { await model.openInZed(repo.id) } }
            Button("Refresh") { Task { await model.refresh(repo.id) } }.disabled(isBusy)
            Divider()
            RemoveSourceAction(repo: repo, model: model)
        }
    }
}
