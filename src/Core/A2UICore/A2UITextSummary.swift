import AgentProtocol
import Foundation

/// Derives host-generated, redacted plaintext for an `A2UISurfaceState` —
/// used for Cmd+F search, TTS, accessible fallback, and durable export.
public enum A2UITextSummary {
    public static func summary(for surface: A2UISurfaceState, maxLength: Int = 4_000) -> String {
        guard let root = surface.rootComponentID else {
            return "[A2UI surface \(surface.surfaceID) — no content yet]"
        }
        var evaluator = A2UIEvaluator(dataModel: surface.redactedDataModel())
        var lines: [String] = []
        var visited: Set<String> = []
        collect(componentID: root, surface: surface, evaluator: &evaluator, into: &lines, visited: &visited, depth: 0)
        let joined = lines.joined(separator: "\n")
        return joined.count > maxLength ? String(joined.prefix(maxLength)) + "…" : joined
    }

    private static func collect(componentID: String,
                                surface: A2UISurfaceState,
                                evaluator: inout A2UIEvaluator,
                                into lines: inout [String],
                                visited: inout Set<String>,
                                depth: Int) {
        guard depth < A2UILimits.maxExpressionDepth, !visited.contains(componentID) else { return }
        visited.insert(componentID)
        guard let component = surface.components[componentID] else { return }
        switch component.body {
        case .text(let props):
            if let resolved = try? evaluator.resolve(props.text), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .button(let props):
            collect(componentID: props.child, surface: surface, evaluator: &evaluator,
                    into: &lines, visited: &visited, depth: depth + 1)
        case .card(let props):
            collect(componentID: props.child, surface: surface, evaluator: &evaluator,
                    into: &lines, visited: &visited, depth: depth + 1)
        case .row(let props), .column(let props):
            for child in childIDs(props.children) {
                collect(componentID: child, surface: surface, evaluator: &evaluator,
                        into: &lines, visited: &visited, depth: depth + 1)
            }
        case .list(let props):
            for child in childIDs(props.children) {
                collect(componentID: child, surface: surface, evaluator: &evaluator,
                        into: &lines, visited: &visited, depth: depth + 1)
            }
        case .tabs(let props):
            for tab in props.tabs {
                if let title = try? evaluator.resolve(tab.title), !title.isEmpty {
                    lines.append(title)
                }
                collect(componentID: tab.child, surface: surface, evaluator: &evaluator,
                        into: &lines, visited: &visited, depth: depth + 1)
            }
        case .modal(let props):
            collect(componentID: props.content, surface: surface, evaluator: &evaluator,
                    into: &lines, visited: &visited, depth: depth + 1)
        case .checkBox(let props):
            if let resolved = try? evaluator.resolve(props.label), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .textField(let props):
            if let resolved = try? evaluator.resolve(props.label), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .choicePicker(let props):
            if let label = props.label, let resolved = try? evaluator.resolve(label), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .slider(let props):
            if let label = props.label, let resolved = try? evaluator.resolve(label), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .dateTimeInput(let props):
            if let label = props.label, let resolved = try? evaluator.resolve(label), !resolved.isEmpty {
                lines.append(resolved)
            }
        case .image, .icon, .video, .audioPlayer, .divider, .unknown:
            break
        }
    }

    /// A repeated-list template contributes its template component once. The
    /// summary is a plaintext fallback, so it deliberately does not expand one
    /// entry per data-model row — that would duplicate identical label text
    /// for every item without adding searchable content.
    private static func childIDs(_ children: A2UIChildList) -> [String] {
        switch children {
        case .fixed(let ids): return ids
        case .template(let componentID, _): return [componentID]
        }
    }
}
