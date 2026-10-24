import SwiftUI
@preconcurrency import FilmCraftKit

// MARK: Panels

/// Panel ids come from the engine (`panelCatalog()`, "panel.<lowerCamel>"); symbols and the short names used in
/// tabs are UI-side. Nothing here is a hard dependency: an id the table does not know still gets a generic panel.
@MainActor
enum PanelUI {
    /// Tabs shown first (top-leading area on iPad, strip on iPhone). Everything else sits under "More".
    static let primary: [String] = [
        "panel.project", "panel.effects", "panel.effectControls",
        "panel.lumetriColor", "panel.essentialGraphics", "panel.audioTrackMixer",
    ]

    static func title(_ id: String) -> String {
        switch id {
        case "panel.project": return String(localized: "Media")
        case "panel.audioTrackMixer": return String(localized: "Audio")
        default: return CommandCatalog.shared.panel(id)?.title ?? fallbackTitle(id)
        }
    }

    private static func fallbackTitle(_ id: String) -> String {
        let name = id.hasPrefix("panel.") ? String(id.dropFirst(6)) : id
        var out = ""
        for ch in name {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func symbol(_ id: String) -> String {
        let table: [String: String] = [
            "panel.project": "photo.on.rectangle", "panel.mediaBrowser": "folder", "panel.libraries": "books.vertical",
            "panel.info": "info.circle", "panel.effects": "wand.and.stars", "panel.markers": "flag",
            "panel.history": "clock.arrow.circlepath", "panel.source": "film", "panel.effectControls": "slider.horizontal.3",
            "panel.audioClipMixer": "slider.vertical.3", "panel.metadata": "tag", "panel.program": "play.rectangle",
            "panel.timeline": "rectangle.split.3x1", "panel.tools": "wrench.and.screwdriver", "panel.audioMeters": "waveform",
            "panel.audioTrackMixer": "speaker.wave.2", "panel.lumetriColor": "paintpalette", "panel.lumetriScopes": "chart.xyaxis.line",
            "panel.essentialGraphics": "text.below.photo", "panel.essentialSound": "ear", "panel.textToSpeech": "text.bubble",
            "panel.properties": "list.bullet.rectangle", "panel.text": "text.alignleft", "panel.events": "bell",
            "panel.progress": "hourglass", "panel.referenceMonitor": "tv", "panel.timecode": "clock", "panel.projectNotes": "note.text",
        ]
        return table[id] ?? "square.on.square"
    }

    /// Every panel the engine lists that is not a primary tab (and is not one of the three zones the layout always shows).
    static func morePanels() -> [PanelInfo] {
        let hidden: Set<String> = ["panel.program", "panel.timeline", "panel.tools"]
        return CommandCatalog.shared.panels.filter { !primary.contains($0.id) && !hidden.contains($0.id) }
    }
}

/// Opens a panel (`panel.<id>`): the tab on a wide iPad, the sheet elsewhere.
@MainActor func uiOpenPanel(_ id: String, model: EditorModel, toggle: Bool = false) {
    if toggle, model.activePanel == id, model.inspectorVisible {
        model.inspectorVisible = false
        return
    }
    model.activePanel = id
    model.inspectorVisible = true
    model.panelRevealTick += 1
}

// MARK: Tools

@MainActor
enum ToolUI {
    static func title(_ id: String) -> String {
        let label = CommandCatalog.shared.tool(id)?.label ?? id
        return label.replacingOccurrences(of: " Tool", with: "")
    }

    static func symbol(_ id: String) -> String {
        let table: [String: String] = [
            "tool.selection": "cursorarrow", "tool.trackSelectForward": "arrow.right.to.line",
            "tool.trackSelectBackward": "arrow.left.to.line", "tool.ripple": "arrow.left.and.right.righttriangle.left.righttriangle.right",
            "tool.rolling": "arrow.left.arrow.right", "tool.rateStretch": "timer", "tool.remix": "slider.horizontal.below.rectangle",
            "tool.razor": "scissors", "tool.slip": "arrow.left.arrow.right.square", "tool.slide": "rectangle.3.group",
            "tool.pen": "pencil.tip", "tool.rectangle": "rectangle", "tool.ellipse": "circle", "tool.hand": "hand.raised",
            "tool.zoom": "magnifyingglass", "tool.type": "textformat", "tool.verticalType": "text.alignleft",
        ]
        return table[id] ?? "scribble"
    }
}

// MARK: Engine queries and JSON helpers

@MainActor
enum EngineQuery {
    /// Runs a command or query by id and decodes its JSON result; nil on any error.
    static func json(_ model: EditorModel, _ id: String, _ params: [String: Any] = [:]) -> Any? {
        guard JSONSerialization.isValidJSONObject(params),
              let body = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: body, encoding: .utf8),
              let out = try? model.handle.execute(id: id, paramsJson: text),
              let data = out.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

func jsonNumber(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
func jsonString(_ any: Any?) -> String? { any as? String }

extension Color {
    /// "#rrggbb" (optionally without the hash); nil when malformed.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

// MARK: Shared modifiers

/// Glass button style that is prominent while `selected`.
struct GlassToggleStyle: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if selected {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

extension View {
    func glassToggle(_ selected: Bool) -> some View { modifier(GlassToggleStyle(selected: selected)) }
}

// MARK: Time and pixel arithmetic (ticks stay Int64; Double only for geometry)

enum TickMath {
    /// Ticks for a (possibly huge or non-finite) double, clamped to a range that cannot overflow later sums.
    static func clampTicks(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        let limit = Double(Int64.max / 4)
        return Int64(max(-limit, min(limit, value)))
    }

    /// Ticks per pixel at a zoom of `pixelsPerSecond`.
    static func ticksPerPixel(_ pixelsPerSecond: Double) -> Double {
        Double(Timecode.ticksPerSecond) / max(0.5, pixelsPerSecond)
    }

    /// Rounds `ticks` to whole frames of the sequence.
    static func snapToFrame(_ ticks: Int64, state: ProjectState) -> Int64 {
        let frame = max(1, Timecode.frameTicks(state))
        let rounded = (Double(ticks) / Double(frame)).rounded()
        return clampTicks(rounded * Double(frame))
    }
}

/// Short "m:ss" / "h:mm:ss" text for ruler labels and durations.
func uiClock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = Int(max(0, min(seconds, 359_999)).rounded(.down))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Carries a value across an isolation boundary when the type is thread-safe but not declared `Sendable` (the UniFFI
/// `ProjectHandle` locks internally). Same pattern as `SendableImage` in `Core/EditorModel.swift`.
struct UIUnchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
