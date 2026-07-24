import Quartz
import SwiftUI

// MARK: - Panel header chrome.

extension View {
    /// The padded, panel-tinted background shared by every panel's top
    /// header row (`DiffPanelView`, `FolderProjectBrowserView`,
    /// `FilePreviewPanel`) and the folder browser's search/filter bars.
    /// `verticalPadding` defaults to the horizontal inset for a square header;
    /// pass a tighter value for a single-line bar.
    func panelHeaderChrome(verticalPadding: CGFloat = Theme.spacing.s16) -> some View {
        padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, verticalPadding)
            .background(Theme.surface.panel)
    }
}

// MARK: - Search / find field bar.

/// A single-line search field with a leading icon and a clear button that
/// appears once there's something to clear. Shared between the folder
/// browser's file search and the log preview's find bar.
struct SearchFieldBar: View {
    let systemImage: String
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let showsClear: Bool
    let clearAccessibilityLabel: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.text.tertiary)
                .imageScale(.small)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.typography.caption)
                .focused(focus)
                .accessibilityLabel(placeholder)
            if showsClear {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearAccessibilityLabel)
            }
        }
        .panelHeaderChrome(verticalPadding: Theme.spacing.s8)
    }
}

// MARK: - Byte counts.

/// Human-readable byte count (e.g. "12 KB"). Shared between the folder
/// browser's file rows and the file-preview header/log-truncation notice.
func byteCountString(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

// MARK: - Quick Look bridge.

/// Minimal `QLPreviewPanelDataSource` serving one file URL.
///
/// Must be retained by the caller (the panel holds an `unowned unsafe` ref) —
/// callers keep it in `@State private var qlBridge`.
final class QuickLookBridge: NSObject, QLPreviewPanelDataSource, @unchecked Sendable {
    // @unchecked Sendable: url is written once before any concurrent use.
    private let url: URL
    init(url: URL) { self.url = url }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }
}

/// Presents `url` in the shared system Quick Look panel and returns the
/// data-source bridge for the caller to retain. Shared by `DiffPanelView`,
/// `FolderProjectBrowserView`, and `FilePreviewPanel`'s Quick Look actions.
@MainActor
@discardableResult
func presentQuickLook(url: URL) -> QuickLookBridge {
    let bridge = QuickLookBridge(url: url)
    let panel = QLPreviewPanel.shared()
    panel?.dataSource = bridge
    panel?.reloadData()
    if panel?.isVisible == true {
        panel?.orderFront(nil)
    } else {
        panel?.makeKeyAndOrderFront(nil)
    }
    return bridge
}

// MARK: - Pill / Tag / Badge — flat, no shadows.

/// Small flat capsule used for inline state.
public struct Pill: View {
    public let label: String
    public let tint: Color

    public init(label: String, tint: Color = Theme.text.tertiary) {
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        Text(label)
            .font(Theme.typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.spacing.s8)
            .padding(.vertical, 2)
            .background(tint.opacity(Theme.opacity.quiet), in: Capsule())
            .accessibilityLabel(label)
    }
}

/// Like `Pill` but with a leading SF Symbol — for resume/auto-approval flags.
public struct Tag: View {
    public let label: String
    public let system: String

    public init(label: String, system: String) {
        self.label = label
        self.system = system
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: system).font(Theme.typography.iconSmall)
                .accessibilityLabel("Status icon")
            Text(label).font(Theme.typography.caption)
        }
        .foregroundStyle(Theme.text.secondary)
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, 3)
        .background(Theme.surface.bubble, in: Capsule())
    }
}

/// Small unread-style number badge.
public struct Badge: View {
    public let count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        Text("\(count)")
            .font(Theme.typography.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.signal.info, in: Capsule())
            .accessibilityLabel("\(count) items")
    }
}

// MARK: - Workspace + connected-clients chips for the top toolbar.

public struct WorkspaceChip: View {
    public let displayName: String

    public init(displayName: String) { self.displayName = displayName }

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "folder.fill")
                .accessibilityLabel("Project")
                .foregroundStyle(Theme.text.secondary)
            Text(displayName)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s4)
        .background(Theme.surface.bubble, in: Capsule())
        .accessibilityLabel("Current project: \(displayName)")
    }
}

public struct ConnectedClientsChip: View {
    /// Toolbar badge when `RemoteControlServer` has ≥1 attached peer.
    /// Tap opens Settings → Remote; device list and revoke live there.
    public let count: Int
    public let onTap: () -> Void

    public init(count: Int, onTap: @escaping () -> Void = {}) {
        self.count = count
        self.onTap = onTap
    }

    public var body: some View {
        if count > 0 {
            Button(action: onTap) {
                HStack(spacing: Theme.spacing.s4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .accessibilityLabel("Remote connection")
                    Text("\(count) connected")
                        .font(Theme.typography.caption)
                }
                .padding(.horizontal, Theme.spacing.s8)
                .padding(.vertical, 3)
                .background(Theme.signal.info.opacity(Theme.opacity.muted), in: Capsule())
                .foregroundStyle(Theme.signal.info)
            }
            .buttonStyle(.plain)
            .help("\(count) remote client\(count == 1 ? "" : "s") attached. Click to open Settings → Remote.")
            .accessibilityLabel("\(count) remote clients attached")
        }
    }
}

// MARK: - Empty state.

public struct EmptyState: View {
    public let system: String
    public let title: String
    public let subtitle: String?

    public init(system: String, title: String, subtitle: String? = nil) {
        self.system = system
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s8) {
            Image(systemName: system)
                .accessibilityLabel("Status icon")
                .font(Theme.typography.emptyState)
                .foregroundStyle(Theme.text.tertiary)
            Text(title)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Floating toast card chrome.

extension View {
    /// The padded card + border + soft drop shadow shared by the workspace's
    /// floating toasts (undo, stalled-turn). Callers build the HStack content
    /// (icon, text, action button); this only unifies the surrounding chrome.
    func toastCardChrome(borderTint: Color = Theme.surface.divider,
                         borderWidth: CGFloat = Theme.stroke.hairline) -> some View {
        padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, Theme.spacing.s12)
            .background(Theme.surface.card, in: RoundedRectangle(cornerRadius: Theme.corner.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium)
                        .stroke(borderTint, lineWidth: borderWidth))
            .shadow(color: .black.opacity(Theme.opacity.faint), radius: 6, y: 3)
    }

    /// Info-tint banner shell used by conversation chrome (loaded-transcript /
    /// auto-scroll-paused). Callers supply the HStack body; this owns padding,
    /// max width, fill, and stroke so the two banners cannot drift apart.
    func infoBannerChrome() -> some View {
        padding(.horizontal, Theme.spacing.s12)
            .padding(.vertical, Theme.spacing.s8)
            .frame(maxWidth: Theme.layout.messageMaxWidth)
            .background(Theme.signal.info.opacity(Theme.opacity.faint),
                        in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous)
                    .stroke(Theme.signal.info.opacity(Theme.opacity.muted),
                            lineWidth: Theme.stroke.standard)
            )
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.top, Theme.spacing.s12)
            .padding(.bottom, Theme.spacing.s4)
    }
}

// MARK: - List highlight navigation.

/// Wraps a list highlight index by `delta` over `count` items. Shared by the
/// composer dropdown, slash palette, and command palette arrow-key handlers.
func wrappingListIndex(current: Int, delta: Int, count: Int) -> Int {
    guard count > 0 else { return current }
    return (current + delta + count) % count
}

// MARK: - Folder chooser sheet shell.

/// Shared chrome for the Open Project / Open Workspace folder-chooser sheets:
/// hero icon, title, caption, primary "Choose Folder…" button, cancel row.
///
/// `footerLeading` sits on the same row as Cancel (e.g. Advanced disclosure).
struct FolderChooserShell<FooterLeading: View>: View {
    let systemImage: String
    let title: String
    let caption: String
    let chooseLabel: String
    let accessibilityChooseLabel: String
    let accessibilityCancelLabel: String
    let width: CGFloat
    let onChoose: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let footerLeading: () -> FooterLeading

    init(systemImage: String,
         title: String,
         caption: String,
         chooseLabel: String,
         accessibilityChooseLabel: String,
         accessibilityCancelLabel: String,
         width: CGFloat,
         onChoose: @escaping () -> Void,
         onCancel: @escaping () -> Void,
         @ViewBuilder footerLeading: @escaping () -> FooterLeading) {
        self.systemImage = systemImage
        self.title = title
        self.caption = caption
        self.chooseLabel = chooseLabel
        self.accessibilityChooseLabel = accessibilityChooseLabel
        self.accessibilityCancelLabel = accessibilityCancelLabel
        self.width = width
        self.onChoose = onChoose
        self.onCancel = onCancel
        self.footerLeading = footerLeading
    }

    var body: some View {
        VStack(spacing: Theme.spacing.s24) {
            VStack(spacing: Theme.spacing.s8) {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                    .font(Theme.typography.heroIcon)
                    .foregroundStyle(Theme.text.tertiary)
                Text(title)
                    .font(Theme.typography.title)
                Text(caption)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Theme.spacing.s32)

            Button(chooseLabel, action: onChoose)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
                .accessibilityLabel(accessibilityChooseLabel)

            HStack(alignment: .top, spacing: Theme.spacing.s12) {
                footerLeading()
                Spacer(minLength: Theme.spacing.s12)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(accessibilityCancelLabel)
            }
            .padding(.horizontal, Theme.spacing.s24)
            .padding(.bottom, Theme.spacing.s24)
        }
        .frame(width: width)
        .fixedSize(horizontal: true, vertical: true)
        .background(Theme.surface.canvas)
    }
}

extension FolderChooserShell where FooterLeading == EmptyView {
    init(systemImage: String,
         title: String,
         caption: String,
         chooseLabel: String,
         accessibilityChooseLabel: String,
         accessibilityCancelLabel: String,
         width: CGFloat,
         onChoose: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.init(
            systemImage: systemImage,
            title: title,
            caption: caption,
            chooseLabel: chooseLabel,
            accessibilityChooseLabel: accessibilityChooseLabel,
            accessibilityCancelLabel: accessibilityCancelLabel,
            width: width,
            onChoose: onChoose,
            onCancel: onCancel,
            footerLeading: { EmptyView() }
        )
    }
}

// MARK: - KbdKey — for tooltips and help text.

public struct KbdKey: View {
    public let glyph: String
    public init(_ glyph: String) { self.glyph = glyph }
    public var body: some View {
        Text(glyph)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surface.bubble, in: RoundedRectangle(cornerRadius: Theme.corner.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner.chip).stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
            .accessibilityLabel("Key \(glyph)")
    }
}

// MARK: - CodeBlock — used in tool renderers.

public struct CodeBlock: View {
    public let text: String
    public let language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.horizontal, Theme.spacing.s8)
                    .padding(.vertical, 4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.primary)
                    .padding(Theme.spacing.s8)
                    .textSelection(.enabled)
            }
        }
        .background(Theme.surface.canvas, in: RoundedRectangle(cornerRadius: Theme.corner.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.small)
                    .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
    }
}
