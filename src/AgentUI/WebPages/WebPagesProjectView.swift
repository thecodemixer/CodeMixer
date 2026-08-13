import SwiftUI
import AgentCore

/// Detail pane for a `ProjectType.webPages` project.
struct WebPagesProjectView: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    @State private var showAddSheet = false

    private var pages: [WebPageEntry] {
        model.webPages(for: project)
    }

    private var selectedPage: WebPageEntry? {
        guard let id = model.activeWebPageID else { return nil }
        return pages.first { $0.id == id }
    }

    private var sessionStoreID: UUID? {
        model.webPageSessionStoreIdentifier(for: project.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.surface.divider)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.canvas)
        .sheet(isPresented: $showAddSheet) {
            WebPageEditorSheet(
                title: "Add Web Page",
                onSave: { entry in
                    model.addWebPage(entry, in: project.path)
                    model.openWebPage(projectPath: project.path, pageID: entry.id)
                    showAddSheet = false
                },
                onCancel: { showAddSheet = false }
            )
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: Theme.spacing.s8) {
            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(!canGoBack)
            .accessibilityLabel("Back")

            Button {
                goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(!canGoForward)
            .accessibilityLabel("Forward")

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(selectedPage == nil)
            .accessibilityLabel("Reload")

            Text(selectedPage?.displayName ?? project.displayName)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let url = selectedPage?.url {
                Button("Open in Browser") {
                    DesktopActions.openURL(url)
                }
                .accessibilityLabel("Open in Browser")

                Button("Copy URL") {
                    DesktopActions.copyToPasteboard(url.absoluteString)
                }
                .accessibilityLabel("Copy URL")
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .foregroundStyle(Theme.text.secondary)
    }

    @ViewBuilder
    private var content: some View {
        if pages.isEmpty {
            ContentUnavailableView {
                Label("No web pages yet", systemImage: "globe")
            } description: {
                Text("Add a URL to embed an external webapp in this project.")
            } actions: {
                Button("Add Web Page…") { showAddSheet = true }
                    .accessibilityLabel("Add Web Page")
            }
        } else if let page = selectedPage,
                  let url = page.url,
                  let storeID = sessionStoreID {
            WebPageViewRepresentable(
                projectPath: project.path,
                pageID: page.id,
                url: url,
                sessionStoreIdentifier: storeID,
                reloadGeneration: model.webPageReloadGeneration
            )
            .accessibilityLabel("Web page \(page.displayName)")
        } else {
            ContentUnavailableView(
                "Select a page",
                systemImage: "globe",
                description: Text("Choose a web page from the sidebar.")
            )
        }
    }

    private var liveWebView: WKWebViewHandle? {
        guard let id = model.activeWebPageID else { return nil }
        return WKWebViewHandle(projectPath: project.path, pageID: id)
    }

    private var canGoBack: Bool {
        liveWebView?.canGoBack ?? false
    }

    private var canGoForward: Bool {
        liveWebView?.canGoForward ?? false
    }

    private func goBack() {
        liveWebView?.goBack()
    }

    private func goForward() {
        liveWebView?.goForward()
    }

    private func reload() {
        liveWebView?.reload()
    }
}

/// Thin accessor so the view file does not import WebKit directly
/// (`check-direct-framework-calls` keeps WebKit under External/).
@MainActor
private struct WKWebViewHandle {
    let projectPath: String
    let pageID: UUID

    var canGoBack: Bool {
        WebPageViewStore.shared.webView(projectPath: projectPath, pageID: pageID)?.canGoBack ?? false
    }

    var canGoForward: Bool {
        WebPageViewStore.shared.webView(projectPath: projectPath, pageID: pageID)?.canGoForward ?? false
    }

    func goBack() {
        WebPageViewStore.shared.webView(projectPath: projectPath, pageID: pageID)?.goBack()
    }

    func goForward() {
        WebPageViewStore.shared.webView(projectPath: projectPath, pageID: pageID)?.goForward()
    }

    func reload() {
        WebPageViewStore.shared.webView(projectPath: projectPath, pageID: pageID)?.reload()
    }
}
