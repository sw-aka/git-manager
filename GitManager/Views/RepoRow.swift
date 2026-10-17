import AppKit
import GitManagerCore
import SwiftUI

struct RepoRow: View {
    let repo: RepoRecord
    let model: AppModel
    let requestRemoval: (Set<UUID>, Bool) -> Void
    let editSource: (UUID) -> Void
    let newGroup: (Set<String>) -> Void
    let dragState: SidebarDragState
    private var isBusy: Bool { model.busy.contains(repo.id) }
    private static let bodyXHeight = NSFont.preferredFont(forTextStyle: .body).xHeight
    private static let captionXHeight = NSFont.preferredFont(forTextStyle: .caption1).xHeight

    private var accessibilitySummary: String {
        var parts = [repo.location.name, "Branch \(repo.status.branch)",
                     "\(repo.status.behind) behind", "\(repo.status.ahead) ahead",
                     repo.status.dirtyCountIsLowerBound
                         ? "At least \(repo.status.dirtyCount) changed files"
                         : "\(repo.status.dirtyCount) changed files"]
        if repo.status.upstream == nil || repo.status.upstreamGone { parts.append(repo.status.badge) }
        if isBusy { parts.append("Updating") }
        if let error = repo.status.error { parts.append("Repository error: \(error)") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let bodyXHeight = Self.bodyXHeight
        let captionXHeight = Self.captionXHeight
        return HStack(spacing: 6) {
            HStack(alignment: .xHeightCenter, spacing: 6) {
                Text(repo.location.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .alignmentGuide(.xHeightCenter) { $0[.firstTextBaseline] - bodyXHeight / 2 }
                Text(repo.status.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .alignmentGuide(.xHeightCenter) { $0[.firstTextBaseline] - captionXHeight / 2 }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if isBusy { ProgressView().controlSize(.mini) }
                if let error = repo.status.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).help(error).accessibilityLabel("Repository error: \(error)")
                }
                if repo.status.dirtyCount > 0 || repo.status.dirtyCountIsLowerBound {
                    HStack(spacing: 3) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text(repo.status.dirtyCountText)
                    }.help(repo.status.dirtyCountIsLowerBound
                           ? "At least \(repo.status.dirtyCount) changed files; status output was truncated"
                           : "\(repo.status.dirtyCount) changed files")
                }
                if repo.status.upstream == nil || repo.status.upstreamGone {
                    Text(repo.status.badge)
                        .foregroundStyle(.secondary)
                        .help(repo.status.upstream ?? "No upstream configured")
                } else {
                    HStack(spacing: 4) {
                        Text("↓\(repo.status.behind)")
                            .foregroundStyle(repo.status.behind == 0 ? .secondary : .primary)
                            .fontWeight(repo.status.behind == 0 ? .regular : .semibold)
                        Text("↑\(repo.status.ahead)")
                            .foregroundStyle(repo.status.ahead == 0 ? .secondary : .primary)
                            .fontWeight(repo.status.ahead == 0 ? .regular : .semibold)
                    }
                    .monospacedDigit()
                    .help(repo.status.upstream ?? "No upstream configured")
                }
            }
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .help(repo.location.displayPath + "\nDrag to reorder or move to a group.")
        .repositoryDropTarget(model: model, groupID: model.organization.groupByRepository[repo.id],
                              dragState: dragState, before: repo.id)
        .contextMenu {
            Button("Sync") { Task { await model.sync(repo.id) } }.disabled(isBusy || !repo.status.canSync)
            OpenInEditorMenu(repo: repo, model: model)
            Button("Refresh") { Task { await model.refresh(repo.id) } }.disabled(isBusy)
            Divider()
            RepositoryGroupMenu(model: model,
                                repositoryIDs: model.selection.contains(repo.id) ? model.selection : [repo.id],
                                newGroup: newGroup)
            Button("Move Up") { model.moveRepository(repo.id, by: -1) }
                .disabled(!model.canMoveRepository(repo.id, by: -1))
            Button("Move Down") { model.moveRepository(repo.id, by: 1) }
                .disabled(!model.canMoveRepository(repo.id, by: 1))
            Divider()
            EditSourceAction(repo: repo, model: model, editSource: editSource)
            RemoveSourceAction(repo: repo, model: model, requestRemoval: requestRemoval, allowsBulkRemoval: true)
        }
    }
}

private extension VerticalAlignment {
    /// Middle of the lowercase letters, so mixed-size text looks vertically centered.
    enum XHeightCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    static let xHeightCenter = VerticalAlignment(XHeightCenter.self)
}
