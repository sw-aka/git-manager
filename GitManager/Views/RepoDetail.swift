import GitManagerCore
import SwiftUI

struct RepoDetail: View {
    let repo: RepoRecord
    let model: AppModel
    let requestRemoval: (Set<UUID>, Bool) -> Void
    let editSource: (UUID) -> Void
    private var isBusy: Bool { model.busy.contains(repo.id) }
    private var isSyncing: Bool { model.syncing.contains(repo.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(repo.location.name).font(.largeTitle.bold())
                    Spacer()
                    if isBusy { ProgressView().controlSize(.small) }
                }
                Text(repo.location.displayPath).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Label(repo.status.branch, systemImage: "arrow.triangle.branch")
                    Text(repo.status.badge).foregroundStyle(.secondary)
                    if repo.status.dirtyCount > 0 || repo.status.dirtyCountIsLowerBound {
                        Label("\(repo.status.dirtyCountText) changed", systemImage: "circle.fill").foregroundStyle(.orange)
                    }
                }.font(.callout)
                if let upstream = repo.status.upstream { Text("Upstream: \(upstream)").font(.caption).foregroundStyle(.secondary) }
                Text(repo.status.lastFetch.map { "Last fetched \(RelativeTime.string($0))" } ?? "Not fetched yet")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { Task { await model.sync(repo.id) } } label: {
                        Label { Text("Sync") } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").symbolEffect(.rotate, isActive: isSyncing)
                        }
                    }.disabled(isBusy || !repo.status.canSync)
                    Button("Open in Zed", systemImage: "arrow.up.right.square") { Task { await model.openInZed(repo.id) } }
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh(repo.id) } }.disabled(isBusy)
                    Spacer()
                    EditSourceAction(repo: repo, model: model, editSource: editSource)
                    RemoveSourceAction(repo: repo, model: model, requestRemoval: requestRemoval)
                }
                if repo.locations.count > 1 {
                    Text("Provided by: " + repo.locations.map { $0.source.title }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if case .local(let folder) = repo.location.source {
                    Text("Source folder: \(folder.path). Removing this source keeps repositories provided by another source.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding([.horizontal, .top], 24)
            if let error = repo.status.error {
                ScrollView {
                    Text(error).font(.callout.monospaced()).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxHeight: 140).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
            }
            Text("Recent commits").font(.headline).padding(.horizontal, 24)
            if repo.commits.isEmpty && isBusy {
                ProgressView("Loading commits...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if repo.commits.isEmpty {
                ContentUnavailableView("No commits", systemImage: "clock", description: Text("Recent commits appear here after status is loaded."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(repo.commits) { commit in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(commit.subject).font(.body.weight(commit.isUnpushed ? .semibold : .regular)).textSelection(.enabled)
                            Spacer()
                            if commit.isUnpushed {
                                Text("Unpushed").font(.caption).foregroundStyle(.orange)
                                    .padding(.horizontal, 7).padding(.vertical, 2).background(.orange.opacity(0.12), in: Capsule())
                            }
                        }
                        HStack {
                            Text(commit.shortHash).font(.caption.monospaced())
                            Text(commit.author).font(.caption)
                            Spacer()
                            Text(RelativeTime.string(commit.date)).font(.caption)
                        }.foregroundStyle(.secondary)
                    }.padding(.vertical, 7)
                        .listRowBackground(commit.isUnpushed ? Color.orange.opacity(0.04) : Color.clear)
                }.listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(repo.location.name)
    }
}
