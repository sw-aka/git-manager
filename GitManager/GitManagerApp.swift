import GitManagerCore
import SwiftUI

@main
struct GitManagerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Git Manager", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 960, minHeight: 580)
                .task { await model.start() }
        }
        .defaultSize(width: 1150, height: 760)
        Settings { SettingsView(model: model) }
        MenuBarExtra(model.menuBarTitle, systemImage: "arrow.triangle.2.circlepath") {
            MenuBarView(model: model)
        }
    }
}
