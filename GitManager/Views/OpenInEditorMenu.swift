import GitManagerCore
import SwiftUI

struct OpenInEditorMenu: View {
    let repo: RepoRecord
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(RepositoryEditor.allCases, id: \.self) { editor in
                Button {
                    Task { await model.openRepository(repo.id, in: editor) }
                } label: {
                    if model.preferredEditor(for: repo.id) == editor {
                        Label(editor.name, systemImage: "checkmark")
                    } else {
                        Text(editor.name)
                    }
                }
            }
        } label: {
            Label("Open in \(model.preferredEditor(for: repo.id).name)", systemImage: "arrow.up.right.square")
        } primaryAction: {
            Task { await model.openRepository(repo.id) }
        }
        .help("Open with the saved editor, or choose an editor for this repository")
    }
}
