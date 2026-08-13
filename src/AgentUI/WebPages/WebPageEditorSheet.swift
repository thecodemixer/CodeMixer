import SwiftUI
import AgentCore

/// Single-page Add / Edit sheet for a web-pages project entry.
struct WebPageEditorSheet: View {
    let title: String
    @State private var displayName: String
    @State private var urlString: String
    let onSave: (WebPageEntry) -> Void
    let onCancel: () -> Void
    private let existingID: UUID?

    init(title: String,
         entry: WebPageEntry? = nil,
         onSave: @escaping (WebPageEntry) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self._displayName = State(initialValue: entry?.displayName ?? "")
        self._urlString = State(initialValue: entry?.urlString ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
        self.existingID = entry?.id
    }

    private var canSave: Bool {
        WebPageEntry.isValidDraftURL(urlString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s16) {
            Text(title)
                .font(Theme.typography.title)
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("Display name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Web page name")
            }
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("URL")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("https://example.com", text: $urlString)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Web page URL")
                if !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !WebPageEntry.isValidDraftURL(urlString) {
                    Text("Enter an http or https URL.")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.danger)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .accessibilityLabel("Cancel")
                Button("Save") {
                    let normalized = WebPageEntry.normalized([
                        WebPageEntry(
                            id: existingID ?? UUID(),
                            displayName: displayName,
                            urlString: urlString
                        )
                    ])
                    guard let entry = normalized.first else { return }
                    onSave(entry)
                }
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Save web page")
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: 420)
    }
}

/// Multi-row editor used by New / Configure Project for web-pages type.
struct WebPageListEditor: View {
    @Binding var pages: [WebPageEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Web pages")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, _ in
                row(at: index)
            }
            Button("Add page") {
                guard pages.count < WebPageEntry.maxPages else { return }
                pages.append(WebPageEntry(displayName: "", urlString: ""))
            }
            .disabled(pages.count >= WebPageEntry.maxPages)
            .accessibilityLabel("Add page")
            Text("URLs without a scheme get https://. Empty list is allowed — add pages later from the sidebar.")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(at index: Int) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.s8) {
            VStack(spacing: Theme.spacing.s4) {
                TextField("Name", text: binding(index, keyPath: \.displayName))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Page \(index + 1) name")
                TextField("https://example.com", text: binding(index, keyPath: \.urlString))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Page \(index + 1) URL")
                let raw = pages[index].urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty, !WebPageEntry.isValidDraftURL(raw) {
                    Text("Invalid URL")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.danger)
                }
            }
            VStack(spacing: Theme.spacing.s4) {
                Button {
                    guard index > 0 else { return }
                    pages.swapAt(index, index - 1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0)
                .accessibilityLabel("Move page \(index + 1) up")
                Button {
                    guard index + 1 < pages.count else { return }
                    pages.swapAt(index, index + 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index + 1 >= pages.count)
                .accessibilityLabel("Move page \(index + 1) down")
                Button(role: .destructive) {
                    pages.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove page \(index + 1)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.tertiary)
        }
    }

    private func binding(_ index: Int, keyPath: WritableKeyPath<WebPageEntry, String>) -> Binding<String> {
        Binding(
            get: {
                guard pages.indices.contains(index) else { return "" }
                return pages[index][keyPath: keyPath]
            },
            set: { newValue in
                guard pages.indices.contains(index) else { return }
                pages[index][keyPath: keyPath] = newValue
            }
        )
    }
}
