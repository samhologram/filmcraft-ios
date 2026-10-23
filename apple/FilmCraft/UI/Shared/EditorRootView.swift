import SwiftUI
import UIKit
import UniformTypeIdentifiers
@preconcurrency import FilmCraftKit

private struct PendingCommand: Identifiable {
    let id: String
}

/// How the editor is laid out for the current window.
enum EditorLayout {
    /// Compact width: viewer, timeline and a bottom tool strip; panels are sheets.
    case phone
    /// A regular-width window narrower than ~900 pt: the iPad zones without the panel column; panels are sheets.
    case padNarrow
    /// Three zones: panels top-leading, viewer top-trailing, timeline across the bottom.
    case padWide

    var panelsAreSheets: Bool { self != .padWide }
}

/// Entry view of an open project: picks the iPad or iPhone layout, publishes the model to the menu bar, and hosts
/// every sheet and alert.
struct EditorRootView: View {
    @Bindable var model: EditorModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.undoManager) private var undoManager

    @State private var layout: EditorLayout = .phone
    @State private var commandItem: PendingCommand?
    @State private var paletteShown = false
    @State private var exportShown = false
    @State private var browserShown = false
    @State private var panelDetent: PresentationDetent = .fraction(0.4)
    /// Work waiting for the panel sheet's dismissal to finish (run from its `onDismiss`).
    @State private var afterPanel: (@MainActor () -> Void)?
    /// Command chosen in the palette, invoked from the palette sheet's `onDismiss`.
    @State private var paletteChoice: String?
    /// A text field or text view has focus: single-key shortcuts must not swallow typing.
    @State private var textEditing = false

    private static let uiTestMode = ProcessInfo.processInfo.arguments.contains("-FilmCraftUITest")

    private var shortcutsEnabled: Bool {
        !(paletteShown || commandItem != nil || exportShown || browserShown || textEditing)
    }

    private var panelSheetShown: Binding<Bool> {
        Binding(
            get: { layout.panelsAreSheets && model.inspectorVisible && model.activePanel != nil },
            set: { model.inspectorVisible = $0 }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let pad = horizontalSizeClass == .regular && geo.size.width >= 700
            let resolved: EditorLayout = !pad ? .phone : (geo.size.width >= 900 ? .padWide : .padNarrow)
            Group {
                if pad {
                    PadEditorView(model: model, showsPanelColumn: resolved == .padWide)
                } else {
                    PhoneEditorView(model: model)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onChange(of: resolved, initial: true) { _, new in layout = new }
        }
        .focusedSceneValue(\.editorModel, model)
        .background { ShortcutButtons(model: model, enabled: shortcutsEnabled) }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in textEditing = true }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in textEditing = false }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in textEditing = true }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { _ in textEditing = false }
        .overlay(alignment: .topLeading) {
            if model.isDemoReady {
                // Marker for UI tests: present once demo seeding finished.
                Color.clear
                    .frame(width: 2, height: 2)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Demo ready")
                    .accessibilityIdentifier("demoReady")
            }
        }
        .overlay(alignment: .topLeading) {
            if Self.uiTestMode {
                // UI-test only (`-FilmCraftUITest`): the catalog ids the app shows, for the test suites to compare
                // against. Not hidden from accessibility, or XCUITest could not read it.
                Color.clear
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Catalog")
                    .accessibilityValue(CatalogDump.json)
                    .accessibilityIdentifier("catalogDump")
            }
        }
        .overlay(alignment: .top) {
            if model.isAddingMedia {
                Label("Adding media\u{2026}", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("mediaAdding")
            }
        }
        .onAppear {
            if model.undoManager == nil { model.undoManager = undoManager }
        }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        // The panel sheet (iPhone, narrow iPad): detents keep the viewer visible and interactive above it.
        .sheet(isPresented: panelSheetShown, onDismiss: runAfterPanel) {
            PanelSheet(model: model)
                .presentationDetents([.fraction(0.4), .medium, .large], selection: $panelDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .presentationContentInteraction(.scrolls)
                .modifier(ErrorAlert(model: model, active: true))
        }
        // Other sheets: shown after the panel sheet has closed, so presentations never collide.
        .sheet(item: $commandItem, onDismiss: { model.pendingCommand = nil }) { item in
            CommandSheet(model: model, commandID: item.id)
        }
        .sheet(isPresented: $paletteShown, onDismiss: {
            model.showCommandPalette = false
            // Invoke once the palette is gone: its command may present another sheet.
            if let id = paletteChoice {
                paletteChoice = nil
                UICommands.invoke(id, model: model)
            }
        }) {
            CommandPaletteView(model: model) { paletteChoice = $0 }
        }
        .sheet(isPresented: $exportShown, onDismiss: { model.showExport = false }) {
            ExportSheet(model: model)
        }
        .sheet(isPresented: $browserShown, onDismiss: { model.showMediaBrowser = false }) {
            MediaBrowserSheet(model: model)
        }
        .onChange(of: model.pendingCommand, initial: true) { _, new in
            if let new {
                presentAfterPanel { commandItem = PendingCommand(id: new) }
            } else {
                commandItem = nil
            }
        }
        .onChange(of: model.showCommandPalette, initial: true) { _, on in
            if on { presentAfterPanel { paletteShown = true } } else { paletteShown = false }
        }
        .onChange(of: model.showExport, initial: true) { _, on in
            if on { presentAfterPanel { exportShown = true } } else { exportShown = false }
        }
        .onChange(of: model.showMediaBrowser, initial: true) { _, on in
            if on { presentAfterPanel { browserShown = true } } else { browserShown = false }
        }
        .modifier(ErrorAlert(model: model, active: !panelSheetShown.wrappedValue))
    }

    /// When the panel sheet is up, close it and present once its dismissal has finished (`onDismiss`).
    private func presentAfterPanel(_ action: @escaping @MainActor () -> Void) {
        if layout.panelsAreSheets && panelSheetShown.wrappedValue {
            afterPanel = action
            model.inspectorVisible = false
        } else {
            action()
        }
    }

    private func runAfterPanel() {
        guard let work = afterPanel else { return }
        afterPanel = nil
        work()
    }
}

/// The catalog as JSON for UI tests: `{"tools":[ids],"panels":[ids],"commands":[ids in the palette]}`.
@MainActor
private enum CatalogDump {
    static let json: String = {
        let cat = CommandCatalog.shared
        let object: [String: [String]] = [
            "tools": cat.tools.map(\.id),
            "panels": cat.panels.map(\.id),
            "commands": UICommands.entries.map(\.id),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }()
}

/// The error alert with the engine's full message. Attached both to the root and to the panel sheet (an alert on the
/// root cannot show while a sheet is up), and only one of them is `active` at a time.
struct ErrorAlert: ViewModifier {
    let model: EditorModel
    let active: Bool

    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(
            get: { active && model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
                .accessibilityIdentifier("errorOK")
        } message: {
            Text(verbatim: model.lastError ?? "")
        }
    }
}

/// Zero-size, invisible buttons that give a hardware keyboard the desktop's single-key shortcuts (tools, J/K/L,
/// space, frame step). `opacity(0)` rather than `hidden()`: a hidden button does not receive its key equivalent.
private struct ShortcutButtons: View {
    let model: EditorModel
    /// False while a sheet is up or a text field has focus.
    let enabled: Bool

    private struct Item: Identifiable {
        let id: String
        let label: String
        let key: KeyEquivalent
        let modifiers: EventModifiers
        let action: @MainActor (EditorModel) -> Void
    }

    private static let items: [Item] = {
        var out: [Item] = []
        for tool in CommandCatalog.shared.tools {
            guard let text = tool.shortcut, !text.isEmpty, let sc = CommandCatalog.parseShortcut(text),
                  !sc.modifiers.contains(.command) else { continue }
            let id = tool.id
            out.append(Item(id: id, label: tool.label, key: sc.key, modifiers: sc.modifiers, action: { $0.runUI(id) }))
        }
        out.append(Item(id: "playback.toggle", label: "Play/Stop", key: .space, modifiers: [], action: { $0.togglePlay() }))
        out.append(Item(id: "playback.forward", label: "Shuttle Right", key: "l", modifiers: [], action: { _ = $0.runUI("playback.forward") }))
        out.append(Item(id: "playback.stop", label: "Shuttle Stop", key: "k", modifiers: [], action: { _ = $0.runUI("playback.stop") }))
        // The engine has no reverse shuttle on iOS yet: J steps back a frame.
        out.append(Item(id: "playback.reverse", label: "Step Back", key: "j", modifiers: [], action: { $0.stepFrame(-1) }))
        out.append(Item(id: "playhead.stepBack", label: "Step Back One Frame", key: .leftArrow, modifiers: [], action: { $0.stepFrame(-1) }))
        out.append(Item(id: "playhead.stepForward", label: "Step Forward One Frame", key: .rightArrow, modifiers: [], action: { $0.stepFrame(1) }))
        return out
    }()

    var body: some View {
        Group {
            ForEach(Self.items) { item in
                Button(item.label) { item.action(model) }
                    .keyboardShortcut(item.key, modifiers: item.modifiers)
            }
        }
        .disabled(!enabled)
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
