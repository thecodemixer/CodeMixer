import Foundation
import AgentCore

extension FolderTreeViewModel {
    func clearPreview() {
        previewTask?.cancel()
        previewGeneration += 1
        previewMode = .none
        previewText = ""
        previewCapped = false
        previewTitle = ""
    }

    func loadPreview(for relativePath: String) {
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        guard let entry = entries.first(where: { $0.relativePath == relativePath }) else {
            previewMode = .none
            previewText = ""
            previewTitle = URL(fileURLWithPath: relativePath).lastPathComponent
            return
        }
        guard !entry.isDirectory else {
            clearPreview()
            previewTitle = entry.name
            return
        }
        previewTitle = entry.name
        let url = absoluteURL(for: relativePath)
        let showSource = docsShowSource
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadFilePreview(
                    at: url,
                    entry: entry,
                    showSource: showSource,
                    generation: generation
                )
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    let message = error.localizedDescription
                    if message.localizedCaseInsensitiveContains("permission")
                        || message.localizedCaseInsensitiveContains("denied") {
                        self.previewMode = .permissionDenied
                    } else {
                        self.previewMode = .error
                    }
                    self.previewText = message
                }
            }
        }
    }

    func setDocsShowSource(_ showSource: Bool) {
        docsShowSource = showSource
        if let selectedRelativePath,
           let entry = selectedEntry,
           FolderFileSupport.isMarkdownFile(entry) {
            loadPreview(for: selectedRelativePath)
        }
    }

    private func loadFilePreview(at url: URL,
                                 entry: FolderFileEntry,
                                 showSource: Bool,
                                 generation: Int) async throws {
        if FolderFileSupport.isMarkdownFile(entry) {
            let document = try FolderFileSupport.loadMarkdownDocument(
                at: url,
                fileSystem: fileSystem,
                includeTOC: false
            )
            await MainActor.run {
                guard generation == self.previewGeneration else { return }
                if document.oversize {
                    self.previewMode = .error
                    self.previewText = FolderFileSupport.oversizeMessage(
                        limit: FolderBrowserLimits.markdownPreviewMaxBytes
                    )
                    return
                }
                if document.isBinary {
                    self.previewMode = .binary
                    self.previewText = ""
                    return
                }
                self.previewText = document.text
                self.previewCapped = false
                self.previewMode = showSource ? .source : .markdown
            }
            return
        }

        let preview = try FolderFileSupport.loadTextPreview(at: url, fileSystem: fileSystem)
        await MainActor.run {
            guard generation == self.previewGeneration else { return }
            if preview.oversize {
                self.previewMode = .error
                self.previewText = FolderFileSupport.oversizeMessage(
                    limit: FolderBrowserLimits.filePreviewMaxBytes
                )
                return
            }
            if preview.isBinary {
                self.previewMode = .binary
                self.previewText = ""
                return
            }
            self.previewText = preview.text
            self.previewCapped = false
            self.previewMode = .text
        }
    }
}
