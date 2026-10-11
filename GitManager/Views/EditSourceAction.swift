import GitManagerCore
import SwiftUI
import Foundation

struct EditSourceAction: View {
    let repo: RepoRecord
    let model: AppModel
    let editSource: (UUID) -> Void

    var body: some View {
        if repo.locations.count == 1 {
            Button("Edit Source...") { editSource(repo.location.source.id) }
        } else {
            Menu("Edit Source") {
                ForEach(model.sources.filter { repo.sourceIDs.contains($0.id) }) { source in
                    Button(source.title) { editSource(source.id) }
                }
            }
        }
    }
}
