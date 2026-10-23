import SwiftUI
@preconcurrency import FilmCraftKit

/// Generic parameter sheet for any engine command: the form is generated from the parsed params doc
/// (`commandParams`). Commands that only read (queries) show their result instead of editing.
struct CommandSheet: View {
    let model: EditorModel
    let commandID: String

    @Environment(\.dismiss) private var dismiss
    @State private var form: CommandForm
    @State private var formError: String?
    @State private var resultText: String?
    @State private var showHelp = false

    init(model: EditorModel, commandID: String) {
        self.model = model
        self.commandID = commandID
        _form = State(initialValue: CommandForm(commandID: commandID))
    }

    private var entry: CommandEntry? { UICommands.byID[commandID] }
    private var title: String { UICommands.label(commandID) }
    private var isQuery: Bool { entry?.isQuery ?? false }
    private var enabled: Bool { model.isEnabled(commandID) }

    var body: some View {
        NavigationStack {
            Form {
                if !enabled, let reason = model.handle.disabledReason(id: commandID) {
                    Section {
                        Label { Text(verbatim: reason) } icon: { Image(systemName: "exclamationmark.triangle") }
                            .foregroundStyle(.orange)
                    }
                }
                if form.usesSelection {
                    Section {
                        Label("Applies to the current selection", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !form.fields.isEmpty {
                    Section("Parameters") {
                        ForEach(form.fields, id: \.key) { field in
                            CommandFieldRow(form: form, field: field)
                        }
                    }
                }
                if form.freeFormLabel != nil || (form.fields.isEmpty && !form.usesSelection) {
                    Section {
                        TextField("{ }", text: $form.freeJSON, axis: .vertical)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(2...8)
                            .accessibilityIdentifier("param.extra")
                    } header: {
                        Text("Extra parameters (JSON)")
                    } footer: {
                        if let label = form.freeFormLabel { Text(verbatim: label) }
                    }
                }
                if let formError {
                    Section("Error") {
                        Text(verbatim: formError).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityIdentifier("commandSheetError")
                    }
                }
                if let resultText {
                    Section("Result") {
                        Text(verbatim: resultText).font(.callout.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("commandSheetResult")
                    }
                }
                if let doc = entry?.doc, !doc.isEmpty {
                    Section {
                        DisclosureGroup("Parameter reference", isExpanded: $showHelp) {
                            Text(verbatim: doc).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("command.\(commandID)")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                        .accessibilityIdentifier("commandSheetCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isQuery ? "Run" : "Apply") { run() }
                        .disabled(!enabled || !form.canRun)
                        .accessibilityIdentifier("commandSheetRun")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func close() {
        model.pendingCommand = nil
        dismiss()
    }

    private func run() {
        formError = nil
        let params: [String: Any]
        do {
            params = try form.params()
        } catch let e as CommandForm.FormError {
            formError = e.message
            return
        } catch {
            formError = error.localizedDescription
            return
        }
        if isQuery {
            runQuery(params)
            return
        }
        model.lastError = nil
        model.run(commandID, params)
        if let failure = model.lastError {
            // Keep the sheet open and show the engine's message here (an alert cannot stack on a sheet).
            formError = failure
            model.lastError = nil
        } else {
            close()
        }
    }

    private func runQuery(_ params: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(params),
              let body = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: body, encoding: .utf8) else {
            formError = "The parameters could not be encoded."
            return
        }
        do {
            let out = try model.handle.execute(id: commandID, paramsJson: text)
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                resultText = CommandForm.pretty(obj)
            } else {
                resultText = out
            }
        } catch {
            formError = error.localizedDescription
        }
    }
}
