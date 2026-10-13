import AppKit
import GitManagerCore
import SwiftUI

struct RepoRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let repo: RepoRecord
    let model: AppModel
    let requestRemoval: (Set<UUID>, Bool) -> Void
    let editSource: (UUID) -> Void
    let newGroup: (Set<String>) -> Void
    @Binding var draggedGroupID: UUID?
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
        HStack(spacing: 6) {
            HStack(alignment: .xHeightCenter, spacing: 6) {
                Text(repo.location.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .alignmentGuide(.xHeightCenter) { $0[.firstTextBaseline] - Self.bodyXHeight / 2 }
                Text(repo.status.branch)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .alignmentGuide(.xHeightCenter) { $0[.firstTextBaseline] - Self.captionXHeight / 2 }
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
        .onDrag {
            draggedGroupID = nil
            return SidebarDragItemProvider.make(for: .repository(repo.id))
        } preview: {
            SidebarDragPreview(name: repo.location.name, detail: repo.status.branch, symbol: "arrow.triangle.branch", colorScheme: colorScheme)
        }
        .repositoryDropTarget(model: model, groupID: model.organization.groupByRepository[repo.id],
                              draggedGroupID: $draggedGroupID, before: repo.id)
        .contextMenu {
            Button("Sync") { Task { await model.sync(repo.id) } }.disabled(isBusy || !repo.status.canSync)
            Button("Open in Zed") { Task { await model.openInZed(repo.id) } }
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

struct SidebarDragPreview: View {
    let name: String
    var detail: String? = nil
    let symbol: String
    let colorScheme: ColorScheme

    // Drag previews render outside the sidebar's environment. Resolve both
    // foreground and background from the source row's appearance explicitly.
    private var foreground: Color { colorScheme == .dark ? .white : .black }
    private var background: Color { Color(white: colorScheme == .dark ? 0.18 : 0.97) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(name).fontWeight(.semibold)
            if let detail { Text(detail).font(.caption).foregroundStyle(foreground.opacity(0.75)) }
        }
        .font(.body)
        .foregroundStyle(foreground)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(foreground.opacity(0.18), lineWidth: 1)
        }
        .environment(\.colorScheme, colorScheme)
    }
}

private extension VerticalAlignment {
    /// Middle of the lowercase letters, so mixed-size text looks vertically centered.
    enum XHeightCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }

    static let xHeightCenter = VerticalAlignment(XHeightCenter.self)
}
