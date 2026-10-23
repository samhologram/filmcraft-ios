import SwiftUI
@preconcurrency import FilmCraftKit

/// The data-driven command system. Wraps the engine catalog (`commandCatalog()`), the desktop UI-only
/// commands (`uiCommandCatalog()`), the desktop menu order (`desktopMenuLayout()`), the timeline tools and the
/// panels. Menus, the command palette and parameter sheets are generated from this.
@MainActor
final class CommandCatalog {
    static let shared = CommandCatalog()

    let commands: [CommandInfo]
    let uiCommands: [UiCommandInfo]
    /// Desktop menu bar order: `items` are command ids, "---" and "@Submenu" placeholders.
    let menus: [MenuSection]
    let tools: [ToolInfo]
    let panels: [PanelInfo]

    private let engineByID: [String: CommandInfo]
    private let uiByID: [String: UiCommandInfo]
    private let panelByID: [String: PanelInfo]
    private var paramCache: [String: [ParamField]] = [:]
    private var supportCache: [String: String?] = [:]

    private init() {
        let engine = commandCatalog()
        let ui = uiCommandCatalog()
        let panelList = panelCatalog()
        commands = engine
        uiCommands = ui
        menus = desktopMenuLayout()
        tools = timelineTools()
        panels = panelList
        engineByID = Dictionary(engine.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        uiByID = Dictionary(ui.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        panelByID = Dictionary(panelList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Lookups

    func command(_ id: String) -> CommandInfo? { engineByID[id] }
    func uiCommand(_ id: String) -> UiCommandInfo? { uiByID[id] }
    func tool(_ id: String) -> ToolInfo? { tools.first { $0.id == id } }
    func panel(_ id: String) -> PanelInfo? { panelByID[id] }

    /// "window.panel.EffectControls" (desktop Window menu) -> "panel.effectControls".
    nonisolated static func panelID(fromWindowCommand id: String) -> String? {
        guard id.hasPrefix("window.panel.") else { return nil }
        let name = String(id.dropFirst("window.panel.".count))
        guard let first = name.first else { return nil }
        return "panel." + first.lowercased() + name.dropFirst()
    }

    /// Resolves "panel.x" and "window.panel.X" to a catalog panel id.
    func resolvePanel(_ id: String) -> String? {
        if panelByID[id] != nil { return id }
        if let mapped = Self.panelID(fromWindowCommand: id), panelByID[mapped] != nil { return mapped }
        return nil
    }

    func isUI(_ id: String) -> Bool {
        if engineByID[id] != nil { return false }
        return uiByID[id] != nil || id.hasPrefix("tool.") || id.hasPrefix("panel.") || resolvePanel(id) != nil
    }

    func isKnown(_ id: String) -> Bool { engineByID[id] != nil || uiByID[id] != nil || resolvePanel(id) != nil || tool(id) != nil }

    func label(_ id: String) -> String {
        if let label = engineByID[id]?.label ?? uiByID[id]?.label { return label }
        if let panel = resolvePanel(id).flatMap({ panelByID[$0] }) { return panel.title }
        if let tool = tool(id) { return tool.label }
        return id
    }

    /// Queries do not journal (no undo step).
    func isQuery(_ id: String) -> Bool { engineByID[id]?.isQuery ?? false }

    func shortcutText(_ id: String) -> String? {
        engineByID[id]?.shortcut ?? uiByID[id]?.shortcut ?? tool(id)?.shortcut
    }

    func shortcut(_ id: String) -> KeyboardShortcut? {
        guard let text = shortcutText(id) else { return nil }
        return Self.parseShortcut(text)
    }

    func params(_ id: String) -> [ParamField] {
        if let cached = paramCache[id] { return cached }
        let fields = commandParams(id: id)
        paramCache[id] = fields
        return fields
    }

    func params(for id: String) -> [ParamField] { params(id) }

    /// A parameter the person must give before the command can run.
    func requiredParams(_ id: String) -> [ParamField] {
        params(id).filter { !$0.key.isEmpty && !$0.isOptional && $0.kind != "ids" && $0.defaultJson == nil }
    }

    /// False for commands that make no sense on iOS (`ios-excluded-commands.txt`).
    func isExcludedOnIOS(_ id: String) -> Bool {
        if let cached = supportCache[id] { return cached != nil }
        let reason = commandPlatformSupport(id: id)
        supportCache[id] = .some(reason)
        return reason != nil
    }

    func isAvailable(_ id: String) -> Bool { !isExcludedOnIOS(id) }

    /// Commands (engine, then UI-only) whose menu path is exactly `path`, in catalog order.
    func commandIDs(menuPath path: [String]) -> [String] {
        commands.filter { $0.menu == path }.map(\.id) + uiCommands.filter { $0.menu == path }.map(\.id)
    }

    // MARK: Shortcut parsing

    /// Parses egui notation: "Cmd+Shift+R", "Shift+G", "E", "=", "Escape". Returns nil for function keys and
    /// anything SwiftUI cannot express.
    nonisolated static func parseShortcut(_ text: String) -> KeyboardShortcut? {
        // "Cmd++" ends in a literal "+": split on the last separator only when a key follows it.
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "", parts.count >= 2 {
            parts.removeLast()
            parts[parts.count - 1] = "+"
        }
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            switch part.lowercased() {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        let key: KeyEquivalent
        switch keyName.lowercased() {
        case "backspace": key = .delete
        case "delete": key = .deleteForward
        case "enter", "return": key = .return
        case "tab": key = .tab
        case "space": key = .space
        case "esc", "escape": key = .escape
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        default:
            guard keyName.count == 1, let ch = keyName.lowercased().first else { return nil }
            key = KeyEquivalent(ch)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }

    /// "Cmd+Shift+R" -> a symbol string for the palette.
    nonisolated static func display(_ text: String) -> String {
        text.split(separator: "+", omittingEmptySubsequences: false).map { part -> String in
            switch part.lowercased() {
            case "cmd": "\u{2318}"
            case "shift": "\u{21E7}"
            case "alt": "\u{2325}"
            case "ctrl": "\u{2303}"
            case "backspace": "\u{232B}"
            case "delete": "\u{2326}"
            case "enter": "\u{21A9}"
            case "escape": "\u{238B}"
            case "space": "\u{2423}"
            default: String(part).uppercased()
            }
        }.joined()
    }
}
