import AppKit
import GitManagerCore
import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationTransferView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var exportedText = ""
    @State private var importedText = ""
    @State private var notice: String?
    @State private var error: String?
    @State private var review: ImportReview?

    private var operationsRunning: Bool { model.isRefreshing || !model.busy.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export / Import Setup").font(.title2.bold())
            if let review {
                reviewContent(review)
            } else {
                Picker("Action", selection: $importing) {
                    Text("Export").tag(false)
                    Text("Import").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: importing) { _, _ in error = nil; notice = nil }

                Text(importing
                     ? "Paste the complete exported text or choose a file. Review it before replacing your current setup."
                     : "Copy or save your folder sources, SSH repositories, nested groups, ordering, and preferences as plain text.")
                    .foregroundStyle(.secondary)
                Group {
                    if importing {
                        TextEditor(text: $importedText)
                    } else {
                        ScrollView {
                            Text(exportedText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .accessibilityLabel(importing ? "Setup text to import" : "Exported setup text")
                Text("Paths and SSH aliases are used as written and must exist on the destination Mac. Git repositories, credentials, and SSH configuration are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                feedback
                HStack {
                    if importing {
                        Button("Paste", action: paste)
                        Button("Choose File…", action: chooseFile)
                    } else {
                        Button("Copy", action: copy)
                            .disabled(exportedText.isEmpty)
                        Button("Save File…", action: saveFile)
                            .disabled(exportedText.isEmpty)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    if importing {
                        Button("Review Import…", action: prepareReview)
                            .disabled(importedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 740, height: 600)
        .onAppear {
            do { exportedText = try model.exportConfiguration() }
            catch { self.error = error.localizedDescription }
        }
        .onExitCommand {
            if review != nil { review = nil; error = nil } else { dismiss() }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        if let notice { Text(notice).foregroundStyle(.secondary) }
    }

    private func reviewContent(_ review: ImportReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace the current setup?").font(.headline)
            Text("Import \(review.imported.sources.count) sources, \(review.imported.organization.groups.count) groups, and \(review.imported.organization.repositoryOrder.count) repository positions. Group nesting, order, expanded state, and preferences will be restored.")
            Text("The current sources listed below will be replaced. Files on disk are not changed.")
            if review.needsReconfirmation {
                Text("The current setup changed while you were reviewing it. Nothing was imported. Review the updated list and confirm again.")
                    .foregroundStyle(.orange)
            }
            if review.removalPlan.entries.isEmpty {
                ContentUnavailableView("No current sources", systemImage: "folder")
            } else {
                List(review.removalPlan.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sourceDescription(entry.source)).textSelection(.enabled)
                        Text("\(entry.repositoryCount) repositories").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.listStyle(.plain)
            }
            Text("Import restores the watch list. Local folders are rescanned; unavailable paths remain configured until they become accessible.")
                .font(.caption).foregroundStyle(.secondary)
            if operationsRunning {
                Text("Waiting for repository operations to finish…").foregroundStyle(.secondary)
            }
            feedback
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { self.review = nil; error = nil }
                    .keyboardShortcut(.defaultAction)
                Button("Replace Setup", role: .destructive) { confirm(review) }
                    .disabled(operationsRunning)
            }
        }
    }

    private func sourceDescription(_ source: RepoSource) -> String {
        switch source {
        case .local(let folder): folder.path
        case .remote(let remote):
            "\(remote.host):\(remote.path)" + (remote.port.map { " (SSH port \($0))" } ?? "")
        }
    }

    private func prepareReview() {
        error = nil; notice = nil
        do {
            let imported = try ConfigurationTransfer.parse(importedText)
            review = ImportReview(text: importedText, imported: imported, previous: model.configurationState,
                                  removalPlan: model.configurationRemovalPlan)
        } catch { self.error = error.localizedDescription }
    }

    private func confirm(_ review: ImportReview) {
        error = nil
        do {
            if try model.importConfiguration(review.text, replacing: review.previous, removalPlan: review.removalPlan) {
                dismiss()
            } else {
                var updated = review
                updated.previous = model.configurationState
                updated.removalPlan = model.configurationRemovalPlan
                updated.needsReconfirmation = true
                self.review = updated
            }
        } catch { self.error = error.localizedDescription }
    }

    private func paste() {
        error = nil; notice = nil
        guard let text = NSPasteboard.general.string(forType: .string) else {
            error = "The clipboard does not contain plain text."
            return
        }
        importedText = text
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(exportedText, forType: .string) {
            error = nil; notice = "Setup copied."
        } else { error = "Could not copy the setup to the clipboard." }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.title = "Export Git Manager Setup"
        panel.nameFieldStringValue = "git-manager-setup.json"
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportedText.write(to: url, atomically: true, encoding: .utf8)
            error = nil; notice = "Saved \(url.lastPathComponent)."
        } catch { self.error = error.localizedDescription }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Git Manager Setup"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importedText = try String(contentsOf: url, encoding: .utf8)
            error = nil; notice = "Loaded \(url.lastPathComponent). Review the text, then choose Review Import."
        } catch { self.error = error.localizedDescription }
    }
}

private struct ImportReview {
    let text: String
    let imported: StoredState
    var previous: StoredState
    var removalPlan: SourceRemovalPlan
    var needsReconfirmation = false
}
