import GitManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct GroupHeaderRow: View {
    let model: AppModel
    let group: RepoGroup?
    let depth: Int
    let dragState: SidebarDragState
    let newSubgroup: (UUID) -> Void
    let rename: (RepoGroup) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false
    @State private var rowHeight: CGFloat = 32
    @FocusState private var addFocused: Bool

    private var title: String { group?.name ?? (model.organization.groups.isEmpty ? "Repositories" : "Ungrouped") }
    private var expanded: Bool { group?.isExpanded ?? model.organization.ungroupedExpanded }
    private var dropPosition: GroupDropPosition? {
        guard case .group(let id, let position) = dragState.target, id == group?.id else { return nil }
        return position
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleExpanded) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")
            nameLabel
            if let group {
                Button { newSubgroup(group.id) } label: {
                    Image(systemName: "plus").frame(width: 20, height: 22)
                }
                .buttonStyle(.borderless)
                .focused($addFocused)
                .opacity(hovered || addFocused ? 1 : 0)
                .help("Create subgroup in \(title)")
                .accessibilityLabel("Create subgroup in \(title)")
            }
            Text("\(model.repositoryCount(in: group?.id))")
                .monospacedDigit()
                .fixedSize()
                .padding(.trailing, 16)
                .accessibilityLabel("\(model.repositoryCount(in: group?.id)) repositories including subgroups")
                .modifier(GroupDragSource(group: group, colorScheme: colorScheme, dragState: dragState))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, CGFloat(depth) * 16)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(dropPosition == .inside ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .top) {
            if dropPosition == .before { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            if dropPosition == .after { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .onHover { hovered = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .onDrop(of: [.plainText], delegate: GroupHeaderDropDelegate(
            model: model, targetID: group?.id, rowHeight: rowHeight,
            dragState: dragState
        ))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 0))
        .help(group == nil
              ? "Drop a group here to move it to the top level, or a repository to make it ungrouped."
              : "Drag groups to the middle to nest them, or to the top or bottom edge to reorder. Drop repositories here to add them.")
        .contextMenu {
            if let group {
                let siblings = model.organization.children(of: group.parentID)
                Button("New Subgroup…") { newSubgroup(group.id) }
                Button(expanded ? "Collapse Group" : "Expand Group", action: toggleExpanded)
                Button("Rename Group…") { rename(group) }
                Button("Move Group Up") { model.moveGroup(group.id, by: -1) }
                    .disabled(siblings.first?.id == group.id)
                Button("Move Group Down") { model.moveGroup(group.id, by: 1) }
                    .disabled(siblings.last?.id == group.id)
                if group.parentID != nil {
                    Button("Move to Top Level") { model.dropGroup(group.id, on: nil, position: .inside) }
                        .disabled(!model.canDropGroup(group.id, on: nil, position: .inside))
                }
                Divider()
                Button("Dissolve Group (Keep Repositories and Subgroups)") { model.removeGroup(group.id) }
            }
        }
    }

    private var nameLabel: some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(GroupDragSource(group: group, colorScheme: colorScheme,
                                      dragState: dragState, click: toggleExpanded))
    }

    private func toggleExpanded() { model.setGroupExpanded(group?.id, to: !expanded) }
}

private struct GroupDragSource: ViewModifier {
    let group: RepoGroup?
    let colorScheme: ColorScheme
    let dragState: SidebarDragState
    var click: (() -> Void)? = nil

    @ViewBuilder func body(content: Content) -> some View {
        if let group {
            content.overlay {
                SidebarDragSource(payload: .group(group.id), state: dragState,
                                  preview: SidebarDragPreview(name: group.name, symbol: "folder", colorScheme: colorScheme),
                                  click: click)
            }
        } else if let click {
            content.onTapGesture(perform: click)
        } else {
            content
        }
    }
}

private struct GroupHeaderDropDelegate: DropDelegate {
    let model: AppModel
    let targetID: UUID?
    let rowHeight: CGFloat
    let dragState: SidebarDragState

    private func position(for info: DropInfo) -> GroupDropPosition {
        guard targetID != nil, case .group = dragState.payload else { return .inside }
        let edge = min(8, rowHeight / 4)
        if info.location.y < edge { return .before }
        if info.location.y > rowHeight - edge { return .after }
        return .inside
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.plainText]), let payload = dragState.payload else { return false }
        switch payload {
        case .group(let id): return model.canDropGroup(id, on: targetID, position: position(for: info))
        case .repository: return true
        }
    }

    func dropEntered(info: DropInfo) { updateTarget(info) }
    func dropExited(info: DropInfo) {
        if case .group(let id, _) = dragState.target, id == targetID { dragState.clearTarget() }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let allowed = updateTarget(info)
        return DropProposal(operation: allowed ? .move : .forbidden)
    }

    @discardableResult
    private func updateTarget(_ info: DropInfo) -> Bool {
        let allowed = validateDrop(info: info)
        if allowed { dragState.hover(.group(targetID, position(for: info))) }
        else { dragState.clearTarget() }
        return allowed
    }

    func performDrop(info: DropInfo) -> Bool {
        dragState.clearTarget()
        guard validateDrop(info: info), let payload = dragState.payload else { return false }
        return model.dropSidebarItem(payload.string, on: targetID, position: position(for: info))
    }
}
