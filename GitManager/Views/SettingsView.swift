import GitManagerCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var transferringSetup = false
    var body: some View {
        Form {
            Stepper(value: Binding(get: { model.settings.validatedInterval }, set: model.setInterval), in: 1...1440) {
                Text("Fetch every \(model.settings.validatedInterval) minutes")
            }
            Text("Git Manager fetches in the background and rescans local folders. Refresh All fetches immediately.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Export / Import Setup…") { transferringSetup = true }
        }
        .sheet(isPresented: $transferringSetup) { ConfigurationTransferView(model: model) }
        .padding(24).frame(width: 430).navigationTitle("Settings")
    }
}
