import GitManagerCore
import SwiftUI
import Foundation

struct RemoveSourceAction: View {
    let repo: RepoRecord
    let model: AppModel
    let requestRemoval: (Set<UUID>, Bool) -> Void
    var allowsBulkRemoval = false

    var body: some View {
        if allowsBulkRemoval && model.selection.count > 1 && model.selection.contains(repo.id) {
            let plan = model.selectedRemovalPlan
            Button("Remove \(plan.entries.count) Sources...", role: .destructive) {
                requestRemoval(plan.sourceIDs, true)
            }
            .disabled(plan.entries.isEmpty)
        } else if repo.locations.count == 1 {
            Button("Remove Source...", role: .destructive) { requestRemoval([repo.location.source.id], false) }
        } else {
            Menu("Remove Source") {
                ForEach(model.sources.filter { repo.sourceIDs.contains($0.id) }) { source in
                    Button(source.title, role: .destructive) { requestRemoval([source.id], false) }
                }
            }
        }
    }
}
