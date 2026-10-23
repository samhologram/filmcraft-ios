import SwiftUI
@preconcurrency import FilmCraftKit

/// Editable state of the generic parameter sheet: one value per `ParamField`, and the conversion back to the JSON
/// object of the engine command. A field is sent when it is required or the user switched it on (untouched optional
/// fields never override the engine's own defaults).
@MainActor @Observable
final class CommandForm {
    struct FormError: Error { let message: String }

    let commandID: String
    /// Fields with a control (the free-form pseudo field and `ids` are not here).
    let fields: [ParamField]
    let usesSelection: Bool
    let freeFormLabel: String?

    var numbers: [String: Double] = [:]
    var texts: [String: String] = [:]
    var flags: [String: Bool] = [:]
    var included: Set<String> = []
    var freeJSON = ""

    init(commandID: String) {
        self.commandID = commandID
        let all = CommandCatalog.shared.params(commandID)
        usesSelection = all.contains { $0.kind == "ids" }
        freeFormLabel = all.first { $0.key.isEmpty }?.label
        fields = all.filter { !$0.key.isEmpty && $0.kind != "ids" }
        for f in fields {
            let def = Self.decode(f.defaultJson)
            switch f.kind {
            case "number", "integer":
                var v = (def as? NSNumber)?.doubleValue ?? f.min ?? 0
                if let lo = f.min { v = max(lo, v) }
                if let hi = f.max { v = min(hi, v) }
                numbers[f.key] = v
            case "bool":
                flags[f.key] = (def as? NSNumber)?.boolValue ?? false
            case "choice":
                var wanted = ""
                if let s = def as? String { wanted = s } else if let n = def as? NSNumber { wanted = Self.numberText(n.doubleValue) }
                if f.choices.contains(wanted) {
                    texts[f.key] = wanted
                } else if let n = def as? NSNumber, n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                          abs(n.doubleValue) < 1e6, f.choices.indices.contains(Int(n.doubleValue)) {
                    // The engine accepts an index for a choice: a numeric default names the option by position.
                    texts[f.key] = f.choices[Int(n.doubleValue)]
                } else {
                    texts[f.key] = f.choices.first ?? ""
                }
            case "json":
                if let def { texts[f.key] = Self.pretty(def) } else { texts[f.key] = "" }
            default:
                texts[f.key] = (def as? String) ?? ""
            }
            if !f.isOptional { included.insert(f.key) }
        }
    }

    private static func decode(_ json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func numberText(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    static func pretty(_ any: Any) -> String {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "\(any)" }
        return s
    }

    /// Int from a Double that may be NaN, infinite or out of range (never traps).
    static func safeInt(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return Int(max(-9e15, min(9e15, v.rounded())))
    }

    /// The engine reads a time param as integer ticks under `time`, or as `timecode` / `seconds` / `frame` (same
    /// optional prefix as the key: `atTime` -> `atTimecode`). A typed value goes under the form it is written in.
    private static func putTime(_ text: String, key: String, into out: inout [String: Any]) {
        let prefix: String
        if key == "time" { prefix = "" }
        else if key.hasSuffix("Time"), key.count > 4 { prefix = String(key.dropLast(4)) }
        else { out[key] = text; return }
        func name(_ base: String) -> String {
            prefix.isEmpty ? base : prefix + base.prefix(1).uppercased() + base.dropFirst()
        }
        if text.contains(":") || text.contains(";") {
            out[name("timecode")] = text
        } else if let seconds = Double(text), seconds.isFinite {
            out[name("seconds")] = seconds
        } else {
            out[name("timecode")] = text
        }
    }

    func isMissingRequired(_ f: ParamField) -> Bool {
        guard !f.isOptional else { return false }
        switch f.kind {
        case "string", "json", "time": return (texts[f.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        default: return false
        }
    }

    var canRun: Bool { !fields.contains(where: isMissingRequired) }

    /// The JSON object for the engine, from the controls plus the free-form JSON.
    func params() throws -> [String: Any] {
        var out: [String: Any] = [:]
        for f in fields where included.contains(f.key) {
            switch f.kind {
            case "number":
                let v = numbers[f.key] ?? 0
                out[f.key] = v.isFinite ? v : 0
            case "integer":
                out[f.key] = Self.safeInt(numbers[f.key] ?? 0)
            case "bool":
                out[f.key] = flags[f.key] ?? false
            case "choice":
                let t = texts[f.key] ?? ""
                if !f.choices.isEmpty, f.choices.allSatisfy({ Double($0) != nil }), let n = Double(t), n.isFinite {
                    if n.rounded() == n, abs(n) < 9e15 { out[f.key] = Self.safeInt(n) } else { out[f.key] = n }
                } else {
                    out[f.key] = t
                }
            case "json":
                let t = (texts[f.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                guard let data = t.data(using: .utf8),
                      let v = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw FormError(message: "\u{201C}\(f.label)\u{201D} is not valid JSON.")
                }
                out[f.key] = v
            case "time":
                let t = (texts[f.key] ?? "").trimmingCharacters(in: .whitespaces)
                if t.isEmpty { if !f.isOptional { out[f.key] = t }; continue }
                Self.putTime(t, key: f.key, into: &out)
            default:
                let t = texts[f.key] ?? ""
                if !t.isEmpty || !f.isOptional { out[f.key] = t }
            }
        }
        let free = freeJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty {
            guard let data = free.data(using: .utf8),
                  let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FormError(message: "The extra parameters must be a JSON object.")
            }
            out.merge(v) { _, new in new }
        }
        return out
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}
