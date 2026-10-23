import SwiftUI
@preconcurrency import FilmCraftKit

/// One parameter of an effect definition (from `effects.list` with `detail`).
struct FXParamInfo: Sendable, Hashable {
    let id: String
    let label: String
    /// "float", "angle", "bool", "choice", "point", "color", "text", "curve", "wheel", "path".
    let type: String
    let animatable: Bool
    let min: Double?
    let max: Double?
    let unit: String
    let options: [String]
}

/// An effect definition: video/audio effect or transition.
struct FXDef: Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    /// "Video", "Audio", "VideoTransition", "AudioTransition".
    let kind: String
    let category: [String]
    let params: [FXParamInfo]
    /// Intrinsic effects (Motion, Opacity, Volume…) are on every clip and cannot be applied or removed.
    var isIntrinsic: Bool { category.isEmpty }
}

/// The engine's effect catalog, loaded once (`effects.list`).
@MainActor
final class FXCatalog {
    static let shared = FXCatalog()
    private(set) var list: [FXDef] = []
    private(set) var byID: [String: FXDef] = [:]
    private var loaded = false
    /// Failed loads so far: a failing query is retried a few times, not on every call.
    private var failures = 0

    func ensureLoaded(_ model: EditorModel) {
        guard !loaded, failures < 3 else { return }
        guard let rows = EngineQuery.json(model, "effects.list", ["detail": true]) as? [[String: Any]] else {
            failures += 1
            return
        }
        loaded = true
        var out: [FXDef] = []
        for row in rows {
            guard let id = jsonString(row["id"]), let name = jsonString(row["name"]) else { continue }
            let kind = jsonString(row["kind"]) ?? "Video"
            let category = (row["category"] as? [String]) ?? []
            var params: [FXParamInfo] = []
            for p in (row["paramInfo"] as? [[String: Any]]) ?? [] {
                guard let pid = jsonString(p["id"]) else { continue }
                params.append(FXParamInfo(
                    id: pid,
                    label: jsonString(p["label"]) ?? pid,
                    type: jsonString(p["type"]) ?? "float",
                    animatable: (p["animatable"] as? Bool) ?? false,
                    min: jsonNumber(p["min"]),
                    max: jsonNumber(p["max"]),
                    unit: jsonString(p["unit"]) ?? "",
                    options: (p["options"] as? [String]) ?? []
                ))
            }
            out.append(FXDef(id: id, name: name, kind: kind, category: category, params: params))
        }
        list = out
        byID = Dictionary(out.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: Clip effect state (decoded from the `.fcproj` JSON, `ProjectHandle.projectJson()`)

/// A parameter value, decoded from the serde JSON of `filmcraft_project::ParamValue`
/// (externally tagged: `{"Float":100.0}`, `{"Vec2":{"x":1,"y":null}}`, `{"Color":[r,g,b,a]}`, ...).
enum FXValue: Sendable, Equatable {
    case float(Double)
    /// A coordinate may be NaN ("auto": the frame or source centre; JSON `null`).
    case point(x: Double, y: Double)
    case color([Double])
    case bool(Bool)
    case choice(Int)
    case text(String)
    /// Curve or path values the panel shows read-only.
    case other(String)

    init(json raw: Any?) {
        guard let obj = raw as? [String: Any], let (tag, payload) = obj.first else { self = .other(""); return }
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double.nan }
        switch tag {
        case "Float": self = .float(num(payload))
        case "Choice": self = .choice((payload as? NSNumber)?.intValue ?? 0)
        case "Bool": self = .bool((payload as? NSNumber)?.boolValue ?? false)
        case "Text": self = .text((payload as? String) ?? "")
        case "Vec2":
            let p = payload as? [String: Any]
            self = .point(x: num(p?["x"]), y: num(p?["y"]))
        case "Color":
            self = .color(((payload as? [Any]) ?? []).map { num($0) })
        case "Curve": self = .other("Curve (\(((payload as? [Any]) ?? []).count) points)")
        case "Path": self = .other("Mask path")
        default: self = .other(tag)
        }
    }

    var float: Double? { if case .float(let v) = self, v.isFinite { return v } else { return nil } }
    var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var choice: Int? { if case .choice(let v) = self { return v } else { return nil } }
    var point: (x: Double, y: Double)? { if case .point(let x, let y) = self { return (x, y) } else { return nil } }
    /// RGB(A) components, at least three.
    var color: [Double]? { if case .color(let c) = self, c.count >= 3 { return c } else { return nil } }
    var text: String? { if case .text(let t) = self { return t } else { return nil } }

    /// Human-readable fallback for read-only rows.
    var summary: String {
        switch self {
        case .float(let v): return String(v)
        case .point(let x, let y): return "\(x.isFinite ? String(x) : "auto"), \(y.isFinite ? String(y) : "auto")"
        case .color(let c): return c.map { String(format: "%.2f", $0) }.joined(separator: ", ")
        case .bool(let b): return b ? "On" : "Off"
        case .choice(let i): return String(i)
        case .text(let t): return t
        case .other(let s): return s
        }
    }

    /// Change token for `onChange` (NaN-safe, unlike `==` on `.point`).
    var changeKey: String { "\(self)" }
}

struct FXParamValue: Sendable {
    let id: String
    let value: FXValue
    let keyframes: Int
}

struct FXInstance: Sendable, Identifiable {
    /// Position in the clip's effect list (what the engine commands call `index`).
    let index: Int
    let effectID: String
    let enabled: Bool
    let masks: Int
    let params: [FXParamValue]
    var id: Int { index }
}

struct FXClip: Sendable {
    let clipID: UInt64
    let name: String
    let isAudio: Bool
    let effects: [FXInstance]
}

enum FXInspect {
    /// Reads one clip's effects from the project JSON (project -> items -> Sequence -> tracks -> items -> effects).
    /// Runs off the main actor: the whole project is parsed. Every key is optional; a damaged or
    /// unexpected shape yields nil rather than a crash.
    // TODO(clipEffectsJson): once the generated bindings expose `clipEffectsJson(clipId:)`, read just this clip's
    // effect stack with it (same per-effect JSON shape: `{effect, enabled, params:{id:{value, keyframes}}, masks}`)
    // and take name / audio-ness from `model.timeline`, instead of serializing and parsing the whole project on
    // every revision (review B item 8). `parseEffects` below is already the shared decoder for that shape.
    nonisolated static func load(handle boxed: UIUnchecked<ProjectHandle>, clipID: UInt64) -> FXClip? {
        let handle = boxed.value
        guard let text = try? handle.projectJson(),
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let project = root["project"] as? [String: Any],
              let items = project["items"] as? [String: Any] else { return nil }
        for (_, rawItem) in items {
            guard let kind = (rawItem as? [String: Any])?["kind"] as? [String: Any],
                  let seq = kind["Sequence"] as? [String: Any] else { continue }
            for (key, isAudio) in [("video_tracks", false), ("audio_tracks", true)] {
                for track in (seq[key] as? [[String: Any]]) ?? [] {
                    for item in (track["items"] as? [[String: Any]]) ?? [] {
                        guard let id = (item["id"] as? NSNumber)?.uint64Value, id == clipID else { continue }
                        let effects = parseEffects((item["effects"] as? [[String: Any]]) ?? [])
                        return FXClip(clipID: clipID, name: (item["name"] as? String) ?? "", isAudio: isAudio, effects: effects)
                    }
                }
            }
        }
        return nil
    }

    /// Decodes an effect stack (`[{effect, enabled, params:{id:{value, keyframes}}, masks}]`).
    nonisolated static func parseEffects(_ raw: [[String: Any]]) -> [FXInstance] {
        var effects: [FXInstance] = []
        for (index, e) in raw.enumerated() {
            var params: [FXParamValue] = []
            for (pid, raw) in (e["params"] as? [String: Any]) ?? [:] {
                guard let p = raw as? [String: Any] else { continue }
                params.append(FXParamValue(
                    id: pid, value: FXValue(json: p["value"]),
                    keyframes: ((p["keyframes"] as? [Any]) ?? []).count))
            }
            effects.append(FXInstance(
                index: index, effectID: (e["effect"] as? String) ?? "",
                enabled: (e["enabled"] as? Bool) ?? true,
                masks: ((e["masks"] as? [Any]) ?? []).count, params: params))
        }
        return effects
    }
}
