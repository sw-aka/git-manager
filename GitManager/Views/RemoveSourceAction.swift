import GitManagerCore
import SwiftUI

struct RemoveSourceAction: View {
    let repo: RepoRecord
    let model: AppModel

    var body: some View {
        if repo.locations.count == 1 {
            Button("Remove Source", role: .destructive) { model.removeSource(repo.location.source.id) }
        } else {
            Menu("Remove Source") {
                ForEach(repo.locations, id: \.source.id) { location in
                    Button(location.source.title, role: .destructive) { model.removeSource(location.source.id) }
                }
            }
        }
    }
}
