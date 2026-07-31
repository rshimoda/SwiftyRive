import SwiftUI
import SwiftyRive

/// The single (leading) sidebar: artboard selection, view options, and one
/// auto-generated control per discovered data-binding property, grouped by
/// parent view-model path. The column is collapsed while no file is open, so
/// this renders nothing in that case.
struct SidebarPanel: View {
    @Bindable var model: InspectorModel

    @State private var isPopoverPresented = false
    @State private var schemaRequest: SchemaSourceRequest?

    var body: some View {
        if let document = model.document {
            controls(for: document)
        } else {
            Color.clear
        }
    }

    private func controls(for document: RiveDocument) -> some View {
        Form {
            Section {
                Picker("Artboard", selection: $model.artboard) {
                    Text("Default").tag(String?.none)
                    ForEach(document.artboardNames, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }
            Section("View") {
                Picker("Fit", selection: $model.fit) {
                    Text("Contain").tag(RiveFit.contain)
                    Text("Cover").tag(RiveFit.cover)
                    Text("Fill").tag(RiveFit.fill)
                    Text("Fit Width").tag(RiveFit.fitWidth)
                    Text("Fit Height").tag(RiveFit.fitHeight)
                    Text("Scale Down").tag(RiveFit.scaleDown)
                    Text("Actual Size").tag(RiveFit.actualSize)
                }
                Toggle("Natural size", isOn: $model.useNaturalSize)
                if model.useNaturalSize {
                    Picker("Axes", selection: $model.naturalAxisMode) {
                        ForEach(NaturalAxisMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                LabeledContent("Authored size", value: model.authoredSizeText)
                Button("Show in Popover") { isPopoverPresented = true }
                    .popover(isPresented: $isPopoverPresented, arrowEdge: .leading) {
                        popoverContent(for: document)
                    }
            }
            propertySections
            // Sits directly under the property sections it describes: the
            // generated schema is those properties, spelled as Swift.
            Section {
                Button {
                    schemaRequest = SchemaSourceRequest(document: document, artboard: model.artboard)
                } label: {
                    Label("Generate Swift Representation", systemImage: "swift")
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $schemaRequest) { request in
            SchemaSourceSheet(request: request)
        }
    }

    @ViewBuilder
    private var propertySections: some View {
        if let instance = model.instance {
            if instance.properties.isEmpty {
                Section("Properties") {
                    Text("The view model has no properties.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(propertyGroups(of: instance), id: \.parent) { group in
                Section {
                    ForEach(group.properties) { property in
                        PropertyRow(property: property, instance: instance)
                    }
                } header: {
                    if group.parent.isEmpty {
                        Text("Properties")
                    } else {
                        Text(group.parent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(group.parent)
                    }
                }
            }
        } else if let bindingNote = model.bindingNote {
            Section("Properties") {
                Text(bindingNote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Deliberately no explicit frame: the popover sizes itself from the
    /// artboard's authored size. Uses the document-based view so the main pane
    /// keeps its advance-nudge registration.
    private func popoverContent(for document: RiveDocument) -> some View {
        RiveView(document, artboard: model.artboard)
            .riveFit(model.fit)
            .riveNaturalSize()
            .padding(8)
            // Safety valve for huge artboards: caps the natural size at
            // 480 pt per axis without defeating natural sizing.
            .frame(maxWidth: 480, maxHeight: 480)
    }

    /// Groups properties by the path of their parent view model ("" = root),
    /// root group first, then parents in order of first appearance.
    private func propertyGroups(
        of instance: RiveDynamicInstance
    ) -> [(parent: String, properties: [RiveDynamicProperty])] {
        var order: [String] = []
        var byParent: [String: [RiveDynamicProperty]] = [:]
        for property in instance.properties {
            let parent: String
            if let slash = property.path.lastIndex(of: "/") {
                parent = String(property.path[..<slash])
            } else {
                parent = ""
            }
            if byParent[parent] == nil {
                order.append(parent)
            }
            byParent[parent, default: []].append(property)
        }
        if let rootIndex = order.firstIndex(of: ""), rootIndex != 0 {
            order.remove(at: rootIndex)
            order.insert("", at: 0)
        }
        return order.map { (parent: $0, properties: byParent[$0] ?? []) }
    }
}

/// One property row: middle-truncated label (full path in the tooltip) plus
/// the kind-specific control in a fixed-width trailing column.
private struct PropertyRow: View {
    let property: RiveDynamicProperty
    let instance: RiveDynamicInstance

    /// Width of the trailing control column, shared by every row so labels
    /// line up and truncate instead of wrapping.
    static let controlWidth: CGFloat = 180

    private var label: String {
        property.path.split(separator: "/").last.map(String.init) ?? property.path
    }

    var body: some View {
        LabeledContent {
            control
                .frame(width: Self.controlWidth, alignment: .trailing)
        } label: {
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(property.path)
    }

    @ViewBuilder
    private var control: some View {
        switch property.kind {
        case .number:
            NumberControl(path: property.path, instance: instance)
        case .bool:
            Toggle(isOn: Binding(
                get: { instance[bool: property.path] ?? false },
                set: { instance[bool: property.path] = $0 }
            )) { EmptyView() }
                .labelsHidden()
        case .string:
            TextField("Text", text: Binding(
                get: { instance[string: property.path] ?? "" },
                set: { instance[string: property.path] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
        case .color:
            ColorPicker(selection: Binding(
                get: { instance[color: property.path].map(Color.init(_:)) ?? .black },
                set: { instance[color: property.path] = RiveColor($0) }
            )) { EmptyView() }
                .labelsHidden()
        case .enum(let cases):
            Picker(selection: Binding(
                get: { instance[enumValue: property.path] ?? "" },
                set: { instance[enumValue: property.path] = $0 }
            )) {
                ForEach(cases, id: \.self) { name in
                    Text(name).tag(name)
                }
            } label: { EmptyView() }
                .labelsHidden()
        case .trigger:
            Button("Fire") { instance.fire(property.path) }
        case .unsupported(let typeName):
            Text(typeName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Slider plus a small editable numeric field. The slider range widens when a
/// value falls outside it, so dragging never rescales mid-gesture.
private struct NumberControl: View {
    let path: String
    let instance: RiveDynamicInstance
    @State private var range: ClosedRange<Double> = 0...100
    @State private var text = ""

    private var value: Double { instance[number: path] ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(
                get: { instance[number: path] ?? 0 },
                set: { instance[number: path] = $0 }
            ), in: range)
            TextField("0", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
                .onSubmit(commit)
        }
        .onAppear {
            widen(for: value)
            text = format(value)
        }
        .onChange(of: value) { _, newValue in
            text = format(newValue)
        }
    }

    private func commit() {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(cleaned), parsed.isFinite else {
            text = format(value)
            return
        }
        widen(for: parsed)
        instance[number: path] = parsed
        text = format(parsed)
    }

    private func widen(for value: Double) {
        if value > range.upperBound {
            range = range.lowerBound...(value * 2)
        }
        if value < range.lowerBound {
            range = (value * 2)...range.upperBound
        }
    }

    private func format(_ value: Double) -> String {
        value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }
}
