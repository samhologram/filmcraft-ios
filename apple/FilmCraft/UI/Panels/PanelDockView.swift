import SwiftUI
@preconcurrency import FilmCraftKit

/// Scene-local iPad panel arrangement. The engine catalog remains the source of available panels.
private struct FilmDockGroup: Codable, Identifiable {
    var id: String = UUID().uuidString
    var tabs: [String]
    var selected: String
    var collapsed = false
}

struct PanelDockView: View {
    @Bindable var model: EditorModel
    @SceneStorage("filmcraft.panelDock.v1") private var storedLayout = ""
    @State private var groups: [FilmDockGroup] = []
    @State private var scrollRequest = 0

    private var catalogIDs: [String] { CommandCatalog.shared.panels.map(\.id) }
    private var defaultGroups: [FilmDockGroup] {
        [FilmDockGroup(tabs: ["panel.project", "panel.effects", "panel.effectControls"], selected: "panel.project")]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Panels").font(.headline)
                Spacer()
                Menu {
                    ForEach(CommandCatalog.shared.panels, id: \.id) { panel in
                        Button { show(panel.id) } label: {
                            Label(PanelUI.title(panel.id), systemImage: isVisible(panel.id) ? "checkmark" : "plus")
                        }
                        .accessibilityIdentifier(panel.id)
                    }
                    Divider()
                    Button("Reset Panels") { reset() }
                        .accessibilityIdentifier("panels.reset")
                } label: {
                    Label("Add panel", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .accessibilityIdentifier("menu.panels")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)

            if groups.isEmpty {
                ContentUnavailableView("No panels", systemImage: "rectangle.stack", description: Text("Add a panel from the menu above."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { vertical in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                panelGroup(group, index: index)
                                    .id(group.id)
                            }
                        }
                        .padding(8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: scrollRequest) { _, _ in
                        guard let id = model.activePanel,
                              let group = groups.first(where: { $0.tabs.contains(id) }) else { return }
                        withAnimation(.smooth) { vertical.scrollTo(group.id, anchor: .top) }
                    }
                }
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
        .onAppear { restore(); synchronizeSelection() }
        .onChange(of: model.activePanel) { _, _ in synchronizeSelection() }
        .onChange(of: model.panelDockResetTick) { _, _ in reset() }
    }

    private func panelGroup(_ group: FilmDockGroup, index: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollViewReader { horizontal in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(group.tabs, id: \.self) { id in
                                Button { show(id) } label: {
                                    Text(PanelUI.title(id))
                                        .font(.subheadline.weight(group.selected == id ? .semibold : .regular))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 10)
                                        .frame(height: 36)
                                        .background(group.selected == id ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier(id)
                                .accessibilityAddTraits(group.selected == id ? .isSelected : [])
                                .id(id)
                                .draggable(id)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let moved = items.first, catalogIDs.contains(moved), moved != id else { return false }
                                    place(moved, before: id)
                                    return true
                                }
                                .contextMenu { tabActions(id, groupID: group.id) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: scrollRequest, initial: true) { _, _ in
                        withAnimation(.smooth) { horizontal.scrollTo(group.selected, anchor: .center) }
                    }
                }
                Button { mutate { $0[index].collapsed.toggle() } } label: {
                    Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                        .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.collapsed ? "Expand panel group" : "Collapse panel group")
                .accessibilityIdentifier("panel.group.\(group.id).collapse")
                Menu {
                    Button("Move Up", systemImage: "arrow.up") { moveGroup(index, by: -1) }
                        .disabled(index == 0)
                    Button("Move Down", systemImage: "arrow.down") { moveGroup(index, by: 1) }
                        .disabled(index == groups.count - 1)
                    Divider()
                    ForEach(group.tabs, id: \.self) { id in
                        Menu(PanelUI.title(id)) { tabActions(id, groupID: group.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 30, height: 36)
                }
                .accessibilityLabel("Panel group options")
                .accessibilityIdentifier("panel.group.\(group.id).menu")
            }
            .padding(.horizontal, 4)
            .background(.bar)
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first, catalogIDs.contains(id) else { return false }
                stack(id, on: group.id)
                return true
            }
            if !group.collapsed {
                Divider()
                panelHeader(group.selected)
                PanelContentView(model: model, panelID: group.selected)
                    .frame(minHeight: 220, maxHeight: 460)
            }
        }
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func panelHeader(_ id: String) -> some View {
        HStack {
            Label(PanelUI.title(id), systemImage: PanelUI.symbol(id))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier("\(id).header")
            Spacer()
            if id == "panel.project" || id == "panel.mediaBrowser" {
                Button { model.showMediaBrowser = true } label: {
                    Label("Import", systemImage: "plus.rectangle.on.folder")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("media.import")
            }
            Button { hide(id) } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Hide \(PanelUI.title(id))")
            .accessibilityIdentifier("panel.\(id).hide")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func tabActions(_ id: String, groupID: String) -> some View {
        Button("Hide \(PanelUI.title(id))", systemImage: "xmark") { hide(id) }
        Button("Move Left", systemImage: "arrow.left") { moveTab(id, by: -1) }
        Button("Move Right", systemImage: "arrow.right") { moveTab(id, by: 1) }
        Button("Move to New Group", systemImage: "rectangle.stack.badge.plus") { separate(id) }
        Menu("Move to Group") {
            ForEach(groups.filter { $0.id != groupID }) { target in
                Button(PanelUI.title(target.selected)) { stack(id, on: target.id) }
            }
        }
    }

    private func isVisible(_ id: String) -> Bool { groups.contains { $0.tabs.contains(id) } }

    private func persist() {
        guard let data = try? JSONEncoder().encode(groups), let value = String(data: data, encoding: .utf8) else { return }
        storedLayout = value
    }

    private func mutate(_ change: (inout [FilmDockGroup]) -> Void) {
        change(&groups)
        persist()
        scrollRequest += 1
    }

    private func restore() {
        if let data = storedLayout.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([FilmDockGroup].self, from: data) {
            let valid = Set(catalogIDs)
            groups = decoded.compactMap { group in
                var seen = Set<String>()
                let tabs = group.tabs.filter { valid.contains($0) && seen.insert($0).inserted }
                guard !tabs.isEmpty else { return nil }
                return FilmDockGroup(id: group.id, tabs: tabs,
                                     selected: tabs.contains(group.selected) ? group.selected : tabs[0],
                                     collapsed: group.collapsed)
            }
        } else {
            groups = defaultGroups
        }
    }

    private func reset() {
        groups = defaultGroups
        model.activePanel = "panel.project"
        model.inspectorVisible = true
        persist()
        scrollRequest += 1
    }

    private func show(_ id: String) {
        guard catalogIDs.contains(id) else { return }
        mutate { layout in
            if let index = layout.firstIndex(where: { $0.tabs.contains(id) }) {
                layout[index].selected = id
                layout[index].collapsed = false
            } else {
                layout.append(FilmDockGroup(tabs: [id], selected: id))
            }
        }
        uiOpenPanel(id, model: model)
    }

    private func synchronizeSelection() {
        guard let id = model.activePanel, catalogIDs.contains(id) else { return }
        show(id)
    }

    private func hide(_ id: String) {
        mutate { layout in
            for index in layout.indices.reversed() where layout[index].tabs.contains(id) {
                layout[index].tabs.removeAll { $0 == id }
                if layout[index].tabs.isEmpty { layout.remove(at: index) }
                else if layout[index].selected == id { layout[index].selected = layout[index].tabs[0] }
            }
        }
        if model.activePanel == id { model.activePanel = groups.first?.selected }
    }

    private func moveGroup(_ index: Int, by offset: Int) {
        let target = index + offset
        guard groups.indices.contains(index), groups.indices.contains(target) else { return }
        mutate { $0.swapAt(index, target) }
    }

    private func moveTab(_ id: String, by offset: Int) {
        guard let groupIndex = groups.firstIndex(where: { $0.tabs.contains(id) }),
              let tabIndex = groups[groupIndex].tabs.firstIndex(of: id),
              groups[groupIndex].tabs.indices.contains(tabIndex + offset) else { return }
        mutate { $0[groupIndex].tabs.swapAt(tabIndex, tabIndex + offset) }
    }

    private func separate(_ id: String) {
        guard isVisible(id) else { return }
        mutate { layout in
            for index in layout.indices.reversed() where layout[index].tabs.contains(id) {
                layout[index].tabs.removeAll { $0 == id }
                if layout[index].tabs.isEmpty { layout.remove(at: index) }
                else if layout[index].selected == id { layout[index].selected = layout[index].tabs[0] }
            }
            layout.append(FilmDockGroup(tabs: [id], selected: id))
        }
        uiOpenPanel(id, model: model)
    }

    private func stack(_ id: String, on targetID: String) {
        guard catalogIDs.contains(id), groups.contains(where: { $0.id == targetID }) else { return }
        if groups.first(where: { $0.id == targetID })?.tabs.contains(id) == true {
            show(id)
            return
        }
        mutate { layout in
            for index in layout.indices.reversed() where layout[index].tabs.contains(id) {
                layout[index].tabs.removeAll { $0 == id }
                if layout[index].tabs.isEmpty { layout.remove(at: index) }
                else if layout[index].selected == id { layout[index].selected = layout[index].tabs[0] }
            }
            guard let target = layout.firstIndex(where: { $0.id == targetID }) else { return }
            layout[target].tabs.append(id)
            layout[target].selected = id
            layout[target].collapsed = false
        }
        uiOpenPanel(id, model: model)
    }

    private func place(_ id: String, before anchor: String) {
        guard let targetID = groups.first(where: { $0.tabs.contains(anchor) })?.id else { return }
        mutate { layout in
            for index in layout.indices.reversed() where layout[index].tabs.contains(id) {
                layout[index].tabs.removeAll { $0 == id }
                if layout[index].tabs.isEmpty { layout.remove(at: index) }
                else if layout[index].selected == id { layout[index].selected = layout[index].tabs[0] }
            }
            guard let target = layout.firstIndex(where: { $0.id == targetID }),
                  let position = layout[target].tabs.firstIndex(of: anchor) else { return }
            layout[target].tabs.insert(id, at: position)
            layout[target].selected = id
            layout[target].collapsed = false
        }
        uiOpenPanel(id, model: model)
    }
}
