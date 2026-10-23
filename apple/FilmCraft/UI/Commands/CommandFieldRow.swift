import SwiftUI
@preconcurrency import FilmCraftKit

/// One row of the generic parameter form, for one `ParamField` (`param.<key>`).
struct CommandFieldRow: View {
    @Bindable var form: CommandForm
    let field: ParamField

    private var key: String { field.key }
    private var includedBinding: Binding<Bool> {
        Binding(
            get: { form.included.contains(key) },
            set: { if $0 { form.included.insert(key) } else { form.included.remove(key) } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.isOptional {
                Toggle(isOn: includedBinding) {
                    Text(verbatim: field.label)
                }
                .accessibilityIdentifier("param.\(key).enabled")
                if form.included.contains(key) { control }
            } else {
                if field.kind != "bool" {
                    Text(verbatim: field.label).font(.subheadline.weight(.medium))
                }
                control
            }
            if !field.doc.isEmpty {
                Text(verbatim: field.doc)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case "number", "integer": numberControl
        case "bool":
            Toggle(isOn: Binding(get: { form.flags[key] ?? false }, set: { form.flags[key] = $0 })) {
                Text(verbatim: field.isOptional ? "Value" : field.label)
            }
            .accessibilityIdentifier("param.\(key)")
        case "choice":
            let selection = Binding(get: { form.texts[key] ?? "" }, set: { form.texts[key] = $0 })
            if field.choices.count <= 4 {
                Picker(selection: selection) {
                    ForEach(field.choices, id: \.self) { c in Text(verbatim: c).tag(c) }
                } label: {
                    Text(verbatim: field.label)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("param.\(key)")
            } else {
                Picker(selection: selection) {
                    ForEach(field.choices, id: \.self) { c in Text(verbatim: c).tag(c) }
                } label: {
                    Text(verbatim: field.label)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("param.\(key)")
            }
        case "json":
            TextField("JSON", text: Binding(get: { form.texts[key] ?? "" }, set: { form.texts[key] = $0 }), axis: .vertical)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2...8)
                .accessibilityIdentifier("param.\(key)")
        default:
            TextField(field.label, text: Binding(get: { form.texts[key] ?? "" }, set: { form.texts[key] = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("param.\(key)")
        }
    }

    private var isInteger: Bool { field.kind == "integer" }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { form.numbers[key] ?? 0 },
            set: { new in
                // Typed input can be NaN, infinite or out of the documented range: never store it.
                guard new.isFinite else { return }
                var v = new
                if let lo = field.min, lo.isFinite { v = max(lo, v) }
                if let hi = field.max, hi.isFinite { v = min(hi, v) }
                form.numbers[key] = v
            }
        )
    }

    @ViewBuilder
    private var numberControl: some View {
        if let lo = field.min, let hi = field.max, lo.isFinite, hi.isFinite, hi > lo {
            HStack {
                Slider(value: numberBinding, in: lo...hi, step: isInteger ? 1 : (hi - lo) / 200)
                    .accessibilityIdentifier("param.\(key)")
                Text(verbatim: CommandForm.numberText(isInteger ? (form.numbers[key] ?? 0).rounded() : ((form.numbers[key] ?? 0) * 100).rounded() / 100))
                    .monospacedDigit()
                    .frame(minWidth: 44, alignment: .trailing)
            }
        } else {
            HStack {
                TextField(field.label, value: numberBinding, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("param.\(key)")
                Stepper("", value: numberBinding, step: isInteger ? 1 : 0.1)
                    .labelsHidden()
            }
        }
    }
}
