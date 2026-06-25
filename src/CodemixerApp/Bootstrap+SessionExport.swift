import UniformTypeIdentifiers
import AgentUI

extension Bootstrap {
    // MARK: - Session export

    enum ExportFormat { case markdown, jsonl, html }

    func exportSession(as format: ExportFormat) {
        guard let model = viewModel else { return }
        let data = buildExport(model.messages, format: format)
        let (ext, type) = exportExtension(format)
        guard let url = DesktopActions.savePanel(nameField: "session.\(ext)",
                                                 allowedTypes: [type]) else { return }
        try? data.write(to: url)
    }

    private func buildExport(_ messages: [EngineViewModel.Message],
                             format: ExportFormat) -> Data {
        switch format {
        case .markdown:
            return SessionExporter.markdown(messages)

        case .jsonl:
            return SessionExporter.jsonl(messages)

        case .html:
            return SessionExporter.html(messages)
        }
    }

    private func exportExtension(_ format: ExportFormat) -> (String, UTType) {
        switch format {
        case .markdown: return ("md", .plainText)
        case .jsonl:    return ("jsonl", .json)
        case .html:     return ("html", .html)
        }
    }
}
