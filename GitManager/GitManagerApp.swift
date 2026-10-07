import GitManagerCore
import SwiftUI

@main
struct GitManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Git Manager", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 960, minHeight: 580)
                .task { await model.start() }
        }
        .defaultSize(width: 1150, height: 760)
        Settings { SettingsView(model: model) }
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                if !model.menuBarTitle.isEmpty {
                    Text(model.menuBarTitle)
                }
            }
        }
    }
}
