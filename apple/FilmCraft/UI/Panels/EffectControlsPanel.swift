import SwiftUI
import UIKit
@preconcurrency import FilmCraftKit

/// Effect Controls: the selected clip's effects and their parameters (Motion, Opacity, Volume, applied effects),
/// edited with `effects.setParam` and friends. Shown for the first selected clip.
struct EffectControlsPanel: View {
    let model: EditorModel

    @State private var clipFX: FXClip?
    @State private var loadedFor: UInt64?

    private var selected: UInt64? { model.state.selectedClips.first }

    private struct LoadKey: Hashable {
        let clip: UInt64?
        let revision: UInt64
    }

    var body: some View {
        Group {
            if selected == nil {
                ContentUnavailableView("No Clip Selected", systemImage: "slider.horizontal.3",
                                       description: Text("Select a clip in the timeline to edit its effects."))
            } else if let fx = clipFX, fx.clipID == selected {
                List {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: fx.isAudio ? "waveform" : "film")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(verbatim: fx.name.isEmpty ? "Clip" : fx.name)
                                .font(.headline)
                                .lineLimit(1)
                            Spacer()
                            if model.state.selectedClips.count > 1 {
                                Text("+\(model.state.selectedClips.count - 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("fxClipName")
                    }
                    ForEach(fx.effects) { effect in
                        EffectSection(model: model, clip: fx.clipID, effect: effect)
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("effectControls")
        .task(id: LoadKey(clip: selected, revision: model.state.revision)) {
            guard let id = selected else { clipFX = nil; return }
            FXCatalog.shared.ensureLoaded(model)
            // While a slider drags the revision changes every frame: wait for the drag to pause before re-reading.
            if loadedFor == id { try? await Task.sleep(for: .milliseconds(120)) }
            if Task.isCancelled { return }
            // ProjectHandle locks internally; the generated class is not known to be Sendable, so carry it unchecked.
            let handle = UIUnchecked(model.handle)
            let result = await Task.detached(priority: .userInitiated) { FXInspect.load(handle: handle, clipID: id) }.value
            if Task.isCancelled { return }
            clipFX = result
            loadedFor = id
        }
    }
}

private struct EffectSection: View {
    let model: EditorModel
    let clip: UInt64
    let effect: FXInstance

    private var def: FXDef? { FXCatalog.shared.byID[effect.effectID] }

    /// The definition's parameters in their own order; parameters the clip carries that the catalog lacks come last.
    private var rows: [(info: FXParamInfo, value: FXParamValue)] {
        var out: [(info: FXParamInfo, value: FXParamValue)] = []
        var seen = Set<String>()
        for info in def?.params ?? [] {
            if let v = effect.params.first(where: { $0.id == info.id }) {
                out.append((info: info, value: v))
                seen.insert(info.id)
            }
        }
        for v in effect.params.sorted(by: { $0.id < $1.id }) where !seen.contains(v.id) {
            out.append((info: FXParamInfo(id: v.id, label: v.id, type: "float", animatable: false, min: nil, max: nil, unit: "", options: []), value: v))
        }
        return out
    }

    var body: some View {
        Section {
            ForEach(rows, id: \.info.id) { row in
                ParamRow(model: model, clip: clip, effect: effect, info: row.info, value: row.value)
            }
            if rows.isEmpty {
                Text("No adjustable parameters.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text(verbatim: def?.name ?? effect.effectID)
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                    .lineLimit(1)
                Spacer()
                Button {
                    model.run("effects.toggleEnabled", ["clip": clip, "index": effect.index])
                } label: {
                    Image(systemName: effect.enabled ? "eye" : "eye.slash")
                }
                .accessibilityLabel(effect.enabled ? "Disable effect" : "Enable effect")
                .accessibilityIdentifier("fx.toggle.\(effect.index)")
                Button {
                    model.run("effects.reset", ["clip": clip, "index": effect.index])
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset effect")
                .accessibilityIdentifier("fx.reset.\(effect.index)")
                if let def, !def.isIntrinsic {
                    Button(role: .destructive) {
                        model.run("effects.remove", ["clip": clip, "index": effect.index])
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Remove effect")
                    .accessibilityIdentifier("fx.remove.\(effect.index)")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("fx.\(effect.index)")
    }
}

private struct ParamRow: View {
    let model: EditorModel
    let clip: UInt64
    let effect: FXInstance
    let info: FXParamInfo
    let value: FXParamValue

    private var widgetID: String { "fx.\(effect.index).\(info.id)" }

    private func set(_ v: Any) {
        model.run("effects.setParam", ["clip": clip, "effect": effect.index, "param": info.id, "value": v])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: info.label).font(.subheadline).lineLimit(1)
                Spacer(minLength: 4)
                if value.keyframes > 0 {
                    Label("\(value.keyframes)", systemImage: "diamond.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
                if info.animatable {
                    Button {
                        model.run("effects.toggleAnimation", ["clip": clip, "effect": effect.index, "param": info.id])
                    } label: {
                        Image(systemName: value.keyframes > 0 ? "stopwatch.fill" : "stopwatch")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(value.keyframes > 0 ? "Stop animating" : "Animate")
                    .accessibilityIdentifier("fx.animate.\(effect.index).\(info.id)")
                }
                Button {
                    model.run("effects.resetParam", ["clip": clip, "effect": effect.index, "param": info.id])
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Reset \(info.label)")
                .accessibilityIdentifier("fx.resetParam.\(effect.index).\(info.id)")
            }
            control
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch info.type {
        case "bool":
            Toggle(isOn: Binding(
                get: { value.value.bool ?? false },
                set: { set($0) }
            )) { Text(verbatim: info.label) }
                .labelsHidden()
                .accessibilityIdentifier(widgetID)
        case "choice":
            Picker(info.label, selection: Binding(
                get: { value.value.choice ?? 0 },
                set: { set($0) }
            )) {
                ForEach(Array(info.options.enumerated()), id: \.offset) { i, name in
                    Text(verbatim: name).tag(i)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier(widgetID)
        case "point":
            PointControl(model: model, value: value, id: widgetID) { x, y in set([x, y]) }
        case "color":
            ColorControl(model: model, value: value, id: widgetID) { hex in set(hex) }
        case "float", "angle":
            if let current = value.value.float {
                FloatControl(model: model, effectID: effect.effectID, info: info, value: current, id: widgetID, label: info.label) { set($0) }
            } else {
                readOnly
            }
        default:
            readOnly
        }
    }

    private var readOnly: some View {
        Text(verbatim: value.value.text ?? String(value.value.summary.prefix(60)))
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .accessibilityIdentifier(widgetID)
    }
}

/// A float parameter: a slider over a practical range (live edits are one undo step) and the exact value.
private struct FloatControl: View {
    let model: EditorModel
    let effectID: String
    let info: FXParamInfo
    let value: Double
    let id: String
    let label: String
    let commit: (Double) -> Void

    @State private var local: Double = 0
    @State private var dragging = false

    /// Practical slider ranges for the intrinsic effects whose hard limits are far wider than anything useful.
    private var range: ClosedRange<Double> {
        let table: [String: ClosedRange<Double>] = [
            "motion.scale": 0...400, "motion.scale_width": 0...400, "motion.anti_flicker": 0...1,
            "opacity.opacity": 0...100, "time_remap.speed": -400...400, "volume.level": -60...15,
            "channel_volume.left": -60...6, "channel_volume.right": -60...6,
        ]
        if let r = table["\(effectID).\(info.id)"] { return r }
        if info.type == "angle" { return -360...360 }
        let lo = info.min ?? -100, hi = info.max ?? 100
        if lo.isFinite, hi.isFinite, hi > lo, hi - lo <= 4000 { return lo...hi }
        let centre = value.isFinite ? value : 0
        return (centre - 200)...(centre + 200)
    }

    private var shown: Double { dragging ? local : value }

    private var format: String {
        let r = range
        return (r.upperBound - r.lowerBound) <= 5 ? "%.2f" : "%.1f"
    }

    var body: some View {
        let r = range
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { min(max(shown.isFinite ? shown : 0, r.lowerBound), r.upperBound) },
                    set: { newValue in
                        guard newValue.isFinite else { return }
                        local = newValue
                        if dragging {
                            commit(newValue)
                        } else {
                            // No editing phase (VoiceOver adjust, Switch Control, keyboard): its own undo step.
                            model.beginDrag("Adjust \(label)")
                            commit(newValue)
                            model.endDrag()
                        }
                    }
                ),
                in: r,
                step: max((r.upperBound - r.lowerBound) / 400, 0.0001)
            ) { editing in
                if editing {
                    local = value
                    dragging = true
                    model.beginDrag("Adjust \(label)")
                } else {
                    dragging = false
                    model.endDrag()
                }
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            Text(verbatim: String(format: format, shown.isFinite ? shown : 0) + (info.unit.isEmpty ? "" : " " + info.unit))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

/// A point parameter (Position, Anchor Point): two numbers; NaN coordinates ("auto") read as the frame centre.
private struct PointControl: View {
    let model: EditorModel
    let value: FXParamValue
    let id: String
    let commit: (Double, Double) -> Void

    @State private var x = ""
    @State private var y = ""

    private var current: (x: Double, y: Double) {
        let p = value.value.point ?? (Double.nan, Double.nan)
        return (p.x.isFinite ? p.x : Double(model.state.width) / 2, p.y.isFinite ? p.y : Double(model.state.height) / 2)
    }

    var body: some View {
        HStack(spacing: 8) {
            field("X", text: $x, suffix: "x")
            field("Y", text: $y, suffix: "y")
        }
        .onAppear(perform: sync)
        .onChange(of: value.value.changeKey) { _, _ in sync() }
    }

    private func sync() {
        let c = current
        x = String(format: "%.1f", c.x)
        y = String(format: "%.1f", c.y)
    }

    private func field(_ label: String, text: Binding<String>, suffix: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let nx = Double(x), let ny = Double(y), nx.isFinite, ny.isFinite { commit(nx, ny) } else { sync() }
                }
                .accessibilityIdentifier("\(id).\(suffix)")
        }
    }
}

private struct ColorControl: View {
    let model: EditorModel
    let value: FXParamValue
    let id: String
    let commit: (String) -> Void

    /// One colour-picker interaction is one undo step: it opens on the first change and closes after a pause.
    @State private var open = false
    @State private var closer: Task<Void, Never>?

    private func edit(_ hex: String) {
        if !open {
            open = true
            model.beginDrag("Adjust Color")
        }
        commit(hex)
        closer?.cancel()
        closer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }
            finish()
        }
    }

    private func finish() {
        closer?.cancel()
        closer = nil
        if open {
            open = false
            model.endDrag()
        }
    }

    var body: some View {
        let c = value.value.color ?? [0, 0, 0, 1]
        ColorPicker("Color", selection: Binding(
            get: { Color(red: c.first ?? 0, green: c.dropFirst().first ?? 0, blue: c.dropFirst(2).first ?? 0) },
            set: { new in
                let resolved = UIColor(new)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
                func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
                edit(String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b)))
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .onDisappear(perform: finish)
        .accessibilityIdentifier(id)
    }
}
