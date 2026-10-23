import SwiftUI
@preconcurrency import FilmCraftKit

/// Renders the catalog commands under a menu path (e.g. `["Clip"]`, `["Clip", "Speed"]`) in the desktop's order: the
/// layout's items first (separators and submenus included), then any commands the layout does not list. Use inside a
/// `Menu` or `contextMenu`.
struct CommandMenuContent: View {
    let model: EditorModel
    let path: [String]

    private enum Item {
        case command(CommandEntry)
        case divider
        case submenu([String])
    }

    private func visible(_ e: CommandEntry) -> Bool { UICommands.unsupportedReason(e.id) == nil }

    /// "@Speed" or "@Clip/Speed" placeholder -> the submenu's path under `path`.
    private func submenuPath(_ raw: String) -> [String] {
        let parts = String(raw.dropFirst()).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return path }
        if let first = path.first, parts.first == first, parts.count > 1 { return parts }
        return path + parts
    }

    private var items: [Item] {
        var out: [Item] = []
        var used = Set<String>()
        var subs = Set<[String]>()
        if path.count == 1, let section = UICommands.layout.first(where: { $0.title == path[0] }) {
            for raw in section.items {
                if raw == "---" {
                    if case .divider? = out.last { continue }
                    if !out.isEmpty { out.append(.divider) }
                } else if raw.hasPrefix("@") {
                    let p = submenuPath(raw)
                    if subs.insert(p).inserted { out.append(.submenu(p)) }
                } else if let e = UICommands.byID[raw], visible(e) {
                    out.append(.command(e))
                    used.insert(e.id)
                } else if let panel = CommandCatalog.shared.resolvePanel(raw),
                          let e = UICommands.byID[UICommands.windowCommandID(for: panel)], visible(e), used.insert(e.id).inserted {
                    out.append(.command(e))
                }
            }
        }
        for e in UICommands.entries where !used.contains(e.id) && e.menu == path && visible(e) {
            out.append(.command(e))
        }
        for e in UICommands.entries where e.menu.count > path.count && Array(e.menu.prefix(path.count)) == path && visible(e) {
            let p = path + [e.menu[path.count]]
            if subs.insert(p).inserted { out.append(.submenu(p)) }
        }
        while case .divider? = out.last { out.removeLast() }
        return out
    }

    private func hasContent(_ p: [String]) -> Bool {
        UICommands.entries.contains { e in
            visible(e) && e.menu.count >= p.count && Array(e.menu.prefix(p.count)) == p
        }
    }

    var body: some View {
        let list = items
        ForEach(Array(list.enumerated()), id: \.offset) { _, item in
            switch item {
            case .command(let e):
                CommandMenuButton(model: model, entry: e)
            case .divider:
                Divider()
            case .submenu(let p):
                if hasContent(p), let name = p.last {
                    Menu(name) {
                        CommandMenuContent(model: model, path: p)
                    }
                    .accessibilityIdentifier("menu.\(p.joined(separator: "."))")
                }
            }
        }
    }
}

/// A menu item for one catalog command (`command.<id>`).
struct CommandMenuButton: View {
    let model: EditorModel
    let entry: CommandEntry

    var body: some View {
        Button {
            UICommands.invoke(entry.id, model: model)
        } label: {
            Text(verbatim: entry.label)
        }
        .disabled(!UICommands.isEnabled(entry, model: model))
        .accessibilityIdentifier("command.\(entry.id)")
    }
}

/// The desktop's menus (File, Edit, Clip, …) as submenus: the overflow menu of both layouts.
struct DesktopMenus: View {
    let model: EditorModel

    var body: some View {
        ForEach(UICommands.layout, id: \.title) { section in
            Menu(section.title) {
                CommandMenuContent(model: model, path: [section.title])
            }
            .accessibilityIdentifier("menu.\(section.title)")
        }
    }
}
