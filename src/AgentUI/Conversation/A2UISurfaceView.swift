import A2UICore
import AgentProtocol
import SwiftUI

/// Renders one A2UI Basic Catalog surface from its canonical, generation-
/// keyed state. This is the single generalized replacement for every
/// vendor-specific "reviewer output" / "structured JSON" text heuristic —
/// any custom ACP tool that emits a `createSurface`/`updateComponents` batch
/// renders here, with zero per-tool knowledge inside `AgentUI`.
///
/// Two-way-bound inputs (`CheckBox`/`TextField`/`Slider`/`ChoicePicker`/
/// `DateTimeInput`) write into a local `overlay` rather than the durable data
/// model — the server, not the renderer, owns `dataModel` (plan §1 "server
/// writes win"). The overlay is only round-tripped when a `Button` with an
/// `event` action fires, via `onInteract`.
///
/// Scope covers the full 18-component Basic Catalog structurally; `Video`,
/// `AudioPlayer`, and `DateTimeInput` render as simplified fallbacks (an
/// external-open link and a plain text field respectively) rather than full
/// native media/calendar widgets — see `docs/architecture.md` A2UI section
/// for that documented limitation.
struct A2UISurfaceView: View {
    let state: A2UISurfaceState
    /// Fired when a `Button` with a server-bound `event` action is tapped.
    /// Parameters: source component id, repeated-list scope paths at that
    /// point in the tree, and the current local overlay (unsynced edits).
    var onInteract: (String, [String], A2UILocalOverlay) -> Void = { _, _, _ in }
    /// Clock reading supplied by the caller for the catalog's `now()`;
    /// `A2UICore` deliberately does not read the system clock itself.
    var now: Date?

    @State private var overlay = A2UILocalOverlay.empty

    var body: some View {
        Group {
            if let rootID = state.rootComponentID {
                componentView(rootID, scopePaths: [])
            } else {
                unrenderablePlaceholder
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s12)
        .background(Theme.surface.bubble,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var unrenderablePlaceholder: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "square.dashed")
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text("Waiting for content…")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
        }
    }

    // MARK: - Dispatch

    /// Type-erased on purpose: the Basic Catalog's `Row`/`Column`/`List`/
    /// `Card`/`Tabs`/`Modal`/`Button` components all recurse back into this
    /// function for their children, so its underlying type would otherwise
    /// have to reference itself — an opaque-`some View` cycle that sends the
    /// type checker into a multi-minute-plus blowup instead of a compile
    /// error. `AnyView` at exactly this one recursive seam keeps every leaf
    /// renderer below (`textView`, `buttonView`, etc.) a normal `some View`.
    private func componentView(_ id: String, scopePaths: [String]) -> AnyView {
        guard let component = state.components[id] else { return AnyView(EmptyView()) }
        return render(component, scopePaths: scopePaths)
    }

    private func render(_ component: A2UIComponent, scopePaths: [String]) -> AnyView {
        switch component.body {
        case .text(let props): return AnyView(textView(props, scopePaths: scopePaths))
        case .divider(let props): return AnyView(dividerView(props))
        case .icon(let props): return AnyView(iconView(props))
        case .image(let props): return AnyView(imageView(props, scopePaths: scopePaths))
        case .video(let props): return AnyView(mediaLinkView(url: props.url, description: nil, isVideo: true, scopePaths: scopePaths))
        case .audioPlayer(let props): return AnyView(mediaLinkView(url: props.url, description: props.description, isVideo: false, scopePaths: scopePaths))
        case .row(let props): return AnyView(stackView(props, axis: .horizontal, scopePaths: scopePaths))
        case .column(let props): return AnyView(stackView(props, axis: .vertical, scopePaths: scopePaths))
        case .list(let props): return AnyView(listView(props, scopePaths: scopePaths))
        case .card(let props): return AnyView(cardView(props, scopePaths: scopePaths))
        case .tabs(let props): return AnyView(tabsView(props, scopePaths: scopePaths))
        case .button(let props): return AnyView(buttonView(component.id, props, scopePaths: scopePaths))
        case .checkBox(let props): return AnyView(checkBoxView(props, scopePaths: scopePaths))
        case .textField(let props): return AnyView(textFieldView(props, scopePaths: scopePaths))
        case .dateTimeInput(let props): return AnyView(dateTimeInputView(props, scopePaths: scopePaths))
        case .choicePicker(let props): return AnyView(choicePickerView(props, scopePaths: scopePaths))
        case .slider(let props): return AnyView(sliderView(props, scopePaths: scopePaths))
        case .modal(let props): return AnyView(modalView(props, scopePaths: scopePaths))
        case .unknown(let opaque): return AnyView(unknownComponentView(opaque))
        }
    }

    // MARK: - Static content

    private func textView(_ props: A2UITextProps, scopePaths: [String]) -> some View {
        let text = resolvedString(props.text, scopePaths: scopePaths)
        let isCaption = props.variant == .caption
        return Text(text)
            .font(isCaption ? Theme.typography.caption : Theme.typography.body)
            .foregroundStyle(isCaption ? Theme.text.secondary : Theme.text.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dividerView(_ props: A2UIDividerProps) -> some View {
        let isVertical = props.axis == .vertical
        return Group {
            if isVertical {
                Divider().frame(height: Theme.spacing.s24)
            } else {
                Divider()
            }
        }
        .background(Theme.surface.divider)
    }

    private func iconView(_ props: A2UIIconProps) -> some View {
        let name = props.name.catalogSymbol ?? "questionmark"
        return Image(systemName: A2UISurfaceStyle.sfSymbol(forCatalogIcon: name))
            .foregroundStyle(Theme.text.secondary)
            .accessibilityLabel(name)
    }

    private func imageView(_ props: A2UIImageProps, scopePaths: [String]) -> some View {
        let urlString = resolvedString(props.url, scopePaths: scopePaths)
        let description = props.description.map { resolvedString($0, scopePaths: scopePaths) }
        return Group {
            if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure:
                        mediaFallbackIcon
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        mediaFallbackIcon
                    }
                }
            } else {
                mediaFallbackIcon
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous))
        .accessibilityLabel(description ?? "Image")
    }

    private var mediaFallbackIcon: some View {
        Image(systemName: "photo")
            .foregroundStyle(Theme.text.tertiary)
            .font(Theme.typography.iconMedium)
            .frame(maxWidth: .infinity, minHeight: Theme.spacing.s48)
    }

    private func mediaLinkView(url: A2UIDynamicString,
                               description: A2UIDynamicString?,
                               isVideo: Bool,
                               scopePaths: [String]) -> some View {
        let urlString = resolvedString(url, scopePaths: scopePaths)
        let descriptionText = description.map { resolvedString($0, scopePaths: scopePaths) }
        let symbol = isVideo ? "play.rectangle" : "waveform"
        return Button {
            if let url = URL(string: urlString) { DesktopActions.openURL(url) }
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: symbol).foregroundStyle(Theme.signal.info)
                Text(descriptionText ?? urlString)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.info)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(descriptionText ?? "Open media")
    }

    // MARK: - Layout

    private func stackView(_ props: A2UIStackProps, axis: Axis, scopePaths: [String]) -> some View {
        let children = childInstances(props.children, scopePaths: scopePaths)
        let alignment = props.align ?? .stretch
        return Group {
            switch axis {
            case .horizontal:
                HStack(alignment: A2UISurfaceStyle.verticalAlignment(alignment), spacing: Theme.spacing.s8) {
                    ForEach(children, id: \.key) { child in
                        componentView(child.id, scopePaths: child.scopePaths)
                    }
                }
            case .vertical:
                VStack(alignment: A2UISurfaceStyle.horizontalAlignment(alignment), spacing: Theme.spacing.s8) {
                    ForEach(children, id: \.key) { child in
                        componentView(child.id, scopePaths: child.scopePaths)
                    }
                }
            }
        }
    }

    private func listView(_ props: A2UIListProps, scopePaths: [String]) -> some View {
        let isHorizontal = props.direction == .horizontal
        let children = childInstances(props.children, scopePaths: scopePaths)
        return Group {
            if isHorizontal {
                ScrollView(.horizontal) {
                    HStack(spacing: Theme.spacing.s8) {
                        ForEach(children, id: \.key) { child in
                            componentView(child.id, scopePaths: child.scopePaths)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                    ForEach(children, id: \.key) { child in
                        componentView(child.id, scopePaths: child.scopePaths)
                    }
                }
            }
        }
    }

    private func cardView(_ props: A2UICardProps, scopePaths: [String]) -> some View {
        componentView(props.child, scopePaths: scopePaths)
            .padding(Theme.spacing.s12)
            .background(Theme.surface.card,
                        in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous)
                .strokeBorder(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
    }

    private func tabsView(_ props: A2UITabsProps, scopePaths: [String]) -> some View {
        let tabs = props.tabs.map { tab in
            (title: resolvedString(tab.title, scopePaths: scopePaths), childID: tab.child)
        }
        return TabsContainerView(tabs: tabs) { childID in
            componentView(childID, scopePaths: scopePaths)
        }
    }

    private func modalView(_ props: A2UIModalProps, scopePaths: [String]) -> some View {
        ModalContainerView(trigger: componentView(props.trigger, scopePaths: scopePaths),
                           content: componentView(props.content, scopePaths: scopePaths))
    }

    // MARK: - Interactive

    private func buttonView(_ id: String, _ props: A2UIButtonProps, scopePaths: [String]) -> some View {
        let variant = props.variant ?? .default
        let fillColor: Color = variant == .primary
            ? Theme.accent.solid.opacity(Theme.opacity.muted)
            : Theme.surface.card
        let borderColor: Color = variant == .borderless ? .clear : Theme.surface.divider
        return Button {
            onInteract(id, scopePaths, overlay)
        } label: {
            componentView(props.child, scopePaths: scopePaths)
                .padding(.horizontal, Theme.spacing.s16)
                .padding(.vertical, Theme.spacing.s8)
        }
        .buttonStyle(.plain)
        .background(fillColor, in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous)
            .strokeBorder(borderColor, lineWidth: Theme.stroke.hairline))
    }

    private func checkBoxView(_ props: A2UICheckBoxProps, scopePaths: [String]) -> some View {
        let label = resolvedString(props.label, scopePaths: scopePaths)
        let path = bindingPath(props.value, scopePaths: scopePaths)
        let resolved = resolvedBool(props.value, scopePaths: scopePaths)
        let binding = Binding<Bool>(get: { path.flatMap { overlay[$0]?.boolValue } ?? resolved },
                                    set: { newValue in if let path { overlay[path] = .bool(newValue) } })
        return Toggle(label, isOn: binding)
            .font(Theme.typography.body)
            .foregroundStyle(Theme.text.primary)
    }

    private func textFieldView(_ props: A2UITextFieldProps, scopePaths: [String]) -> some View {
        let label = resolvedString(props.label, scopePaths: scopePaths)
        let path = props.value.flatMap { bindingPath($0, scopePaths: scopePaths) }
        let resolved = props.value.map { resolvedString($0, scopePaths: scopePaths) } ?? ""
        let variant = props.variant ?? .shortText
        let binding = Binding<String>(get: { path.flatMap { overlay[$0]?.stringValue } ?? resolved },
                                      set: { newValue in if let path { overlay[path] = .string(newValue) } })
        return VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            Text(label).font(Theme.typography.caption).foregroundStyle(Theme.text.secondary)
            if variant.isObscured {
                SecureField("", text: binding).textFieldStyle(.roundedBorder)
            } else {
                TextField("", text: binding, axis: variant == .longText ? .vertical : .horizontal)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(variant == .longText ? 3...8 : 1...1)
            }
        }
        .font(Theme.typography.body)
    }

    /// Simplified: a plain ISO 8601 text field rather than a native
    /// calendar/time widget — see file header for scope note.
    private func dateTimeInputView(_ props: A2UIDateTimeInputProps, scopePaths: [String]) -> some View {
        let path = bindingPath(props.value, scopePaths: scopePaths)
        let resolved = resolvedString(props.value, scopePaths: scopePaths)
        let label = props.label.map { resolvedString($0, scopePaths: scopePaths) } ?? "Date/time"
        let binding = Binding<String>(get: { path.flatMap { overlay[$0]?.stringValue } ?? resolved },
                                      set: { newValue in if let path { overlay[path] = .string(newValue) } })
        return VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            Text(label).font(Theme.typography.caption).foregroundStyle(Theme.text.secondary)
            TextField("YYYY-MM-DD", text: binding).textFieldStyle(.roundedBorder)
        }
        .font(Theme.typography.body)
    }

    private func sliderView(_ props: A2UISliderProps, scopePaths: [String]) -> some View {
        let label = props.label.map { resolvedString($0, scopePaths: scopePaths) }
        let path = bindingPath(props.value, scopePaths: scopePaths)
        let minValue = props.min ?? 0
        let maxValue = max(props.max, minValue + 0.0001)
        let resolved = resolvedNumber(props.value, scopePaths: scopePaths)
        let binding = Binding<Double>(get: { path.flatMap { overlay[$0]?.numberValue } ?? resolved },
                                      set: { newValue in if let path { overlay[path] = .number(newValue) } })
        return VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            if let label {
                Text(label).font(Theme.typography.caption).foregroundStyle(Theme.text.secondary)
            }
            Slider(value: binding, in: minValue...maxValue)
        }
    }

    private func choicePickerView(_ props: A2UIChoicePickerProps, scopePaths: [String]) -> some View {
        let label = props.label.map { resolvedString($0, scopePaths: scopePaths) }
        let path = bindingPath(props.value, scopePaths: scopePaths)
        let resolvedSelection = Set((path.flatMap { overlay[$0]?.arrayValue }
                ?? resolvedArray(props.value, scopePaths: scopePaths)).compactMap(\.stringValue))
        let isMultiple = props.variant == .multipleSelection
        let options = props.options.map { option in
            (label: resolvedString(option.label, scopePaths: scopePaths), value: option.value)
        }
        return VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            if let label {
                Text(label).font(Theme.typography.caption).foregroundStyle(Theme.text.secondary)
            }
            ForEach(options, id: \.value) { option in
                let isSelected = resolvedSelection.contains(option.value)
                Button {
                    guard let path else { return }
                    var next = resolvedSelection
                    if isMultiple {
                        if isSelected { next.remove(option.value) } else { next.insert(option.value) }
                    } else {
                        next = [option.value]
                    }
                    overlay[path] = .array(next.map { .string($0) })
                } label: {
                    HStack(spacing: Theme.spacing.s8) {
                        Image(systemName: A2UISurfaceStyle.choiceGlyph(isMultiple: isMultiple, selected: isSelected))
                            .foregroundStyle(isSelected ? Theme.accent.solid : Theme.text.tertiary)
                            .accessibilityHidden(true)
                        Text(option.label).font(Theme.typography.body).foregroundStyle(Theme.text.primary)
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func unknownComponentView(_ opaque: A2UIOpaqueComponent) -> some View {
        // Plan §1 "unknown component/catalog degrade gracefully" — never
        // crash or drop content silently; show what we can identify.
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "questionmark.square.dashed")
                .foregroundStyle(Theme.signal.warning)
                .accessibilityHidden(true)
            Text("Unsupported component: \(opaque.kindName)")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
        }
    }

    // MARK: - Data binding helpers

    private func evaluator(scopePaths: [String]) -> A2UIEvaluator {
        A2UIEvaluator(dataModel: state.dataModel, overlay: overlay, scopePaths: scopePaths, now: now)
    }

    private func resolvedString(_ value: A2UIDynamicString, scopePaths: [String]) -> String {
        var evaluator = evaluator(scopePaths: scopePaths)
        return (try? evaluator.resolve(value)) ?? ""
    }

    private func resolvedBool(_ value: A2UIDynamicBoolean, scopePaths: [String]) -> Bool {
        var evaluator = evaluator(scopePaths: scopePaths)
        return (try? evaluator.resolve(value)) ?? false
    }

    private func resolvedNumber(_ value: A2UIDynamicNumber, scopePaths: [String]) -> Double {
        var evaluator = evaluator(scopePaths: scopePaths)
        let resolved = try? evaluator.resolve(value)
        return resolved.flatMap { $0.isNaN ? nil : $0 } ?? 0
    }

    private func resolvedArray(_ value: A2UIDynamicStringList, scopePaths: [String]) -> [A2UIResolvedValue] {
        var evaluator = evaluator(scopePaths: scopePaths)
        return (try? evaluator.resolve(value.asDynamicValue))?.arrayValue ?? []
    }

    /// Extracts the absolute data-model path a two-way-bound property is
    /// wired to (path bindings only — literal defaults have no write-back
    /// target and stay local-only for that render).
    private func bindingPath(_ value: A2UIDynamicString, scopePaths: [String]) -> A2UIJSONPointerPath? {
        guard case .binding(let binding) = value else { return nil }
        return A2UIJSONPointerPath(A2UIJSONPointer.resolveScoped(binding.path, scopePaths: scopePaths))
    }

    private func bindingPath(_ value: A2UIDynamicBoolean, scopePaths: [String]) -> A2UIJSONPointerPath? {
        guard case .binding(let binding) = value else { return nil }
        return A2UIJSONPointerPath(A2UIJSONPointer.resolveScoped(binding.path, scopePaths: scopePaths))
    }

    private func bindingPath(_ value: A2UIDynamicNumber, scopePaths: [String]) -> A2UIJSONPointerPath? {
        guard case .binding(let binding) = value else { return nil }
        return A2UIJSONPointerPath(A2UIJSONPointer.resolveScoped(binding.path, scopePaths: scopePaths))
    }

    private func bindingPath(_ value: A2UIDynamicStringList, scopePaths: [String]) -> A2UIJSONPointerPath? {
        guard case .binding(let binding) = value else { return nil }
        return A2UIJSONPointerPath(A2UIJSONPointer.resolveScoped(binding.path, scopePaths: scopePaths))
    }

    private struct ChildInstance { let id: String; let scopePaths: [String]; let key: String }

    /// Resolves a `ChildList`: either a fixed array of component ids, or a
    /// `{componentId, path}` template repeating over a data-model list — the
    /// Basic Catalog's one repeated-list mechanism.
    private func childInstances(_ children: A2UIChildList, scopePaths: [String]) -> [ChildInstance] {
        switch children {
        case .fixed(let ids):
            return ids.enumerated().map { offset, id in
                ChildInstance(id: id, scopePaths: scopePaths, key: "\(id)#\(offset)")
            }
        case .template(let templateID, let path):
            let resolvedPath = A2UIJSONPointer.resolveScoped(path, scopePaths: scopePaths)
            let items = A2UIJSONPointer.value(at: resolvedPath, in: state.dataModel)?.arrayValue ?? []
            return items.prefix(A2UILimits.maxListExpansion).indices.map { index in
                let itemScope = scopePaths + ["\(resolvedPath)/\(index)"]
                return ChildInstance(id: templateID, scopePaths: itemScope, key: "\(templateID)#\(resolvedPath)#\(index)")
            }
        }
    }
}

/// AppKit-free tab strip so `Tabs` doesn't depend on `NSTabView` wrapping.
private struct TabsContainerView<Content: View>: View {
    let tabs: [(title: String, childID: String)]
    @ViewBuilder let content: (String) -> Content

    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            if tabs.count > 1 {
                HStack(spacing: Theme.spacing.s16) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button {
                            selectedIndex = index
                        } label: {
                            Text(tab.title)
                                .font(Theme.typography.label)
                                .foregroundStyle(index == selectedIndex ? Theme.text.primary : Theme.text.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if tabs.indices.contains(selectedIndex) {
                content(tabs[selectedIndex].childID)
            }
        }
    }
}

private struct ModalContainerView: View {
    let trigger: AnyView
    let content: AnyView

    @State private var isPresented = false

    var body: some View {
        trigger
            .onTapGesture { isPresented = true }
            .sheet(isPresented: $isPresented) {
                content
                    .padding(Theme.spacing.s24)
                    .frame(minWidth: Theme.layout.settingsMinWidth)
            }
    }
}
