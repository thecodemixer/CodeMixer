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
        // Do not pair the new URL with the previous file's renderer while the
        // debounced load settles (for example, treating a PDF as an image).
        previewMode = .none
        previewText = ""
        previewCapped = false
        let url = absoluteURL(for: relativePath)
        let showSource = docsShowSource
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: FolderBrowserLimits.previewSelectionDebounce)
                try Task.checkCancellation()
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
           FolderFileSupport.hasRenderedAndSourceViews(entry) {
            loadPreview(for: selectedRelativePath)
        }
    }

    private func loadFilePreview(at url: URL,
                                 entry: FolderFileEntry,
                                 showSource: Bool,
                                 generation: Int) async throws {
        let contentKind = FolderFileSupport.previewContentKind(for: entry)
        // These render from the URL. Reading the bytes here would only classify
        // them as binary and throw the document away.
        if let renderedMode = FolderFileSupport.urlRenderedMode(
            for: contentKind,
            showSource: showSource
        ) {
            await MainActor.run {
                guard generation == self.previewGeneration else { return }
                self.previewMode = renderedMode
                self.previewText = ""
                self.previewCapped = false
            }
            return
        }

        let fileSystem = fileSystem
        if contentKind == .markdown {
            let document = try await FolderFileSupport.offMainActor {
                try FolderFileSupport.loadMarkdownDocument(
                    at: url,
                    fileSystem: fileSystem,
                    includeTOC: false
                )
            }
            try Task.checkCancellation()
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

        let preview = try await FolderFileSupport.offMainActor {
            try FolderFileSupport.loadTextPreview(at: url, fileSystem: fileSystem)
        }
        try Task.checkCancellation()
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
            self.previewMode = contentKind == .web ? .source : .text
        }
    }
}
