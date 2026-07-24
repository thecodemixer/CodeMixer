import SwiftUI
import AgentCore

/// The file-listing `Table` variants (compact name-only beside a preview,
/// full plain, full with a Pin column) plus their shared row/cell/context-menu
/// helpers. Split out of `FolderProjectBrowserView.swift` because the table
/// itself — three near-identical column sets, a sort comparator, and the
/// per-row context menu — is the largest self-contained concern in that view.
extension FolderProjectBrowserView {
    @ViewBuilder
    func fileTable(_ browser: FolderProjectBrowserModel, compact: Bool) -> some View {
        // Beside preview, keep a name-only list — Pin column is full-list only.
        if compact {
            compactPlainFileTable(browser)
        } else if kind.supportsPinnedSidebarEntries {
            fullPinnedFileTable(browser)
        } else {
            fullPlainFileTable(browser)
        }
    }

    func compactPlainFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(of: FolderFileEntry.self, selection: Binding(
            get: { browser.selectedPaths },
            set: { browser.selectMany($0) }
        )) {
            TableColumn("Name") { (entry: FolderFileEntry) in
                fileNameCell(entry)
            }
            .width(min: Theme.layout.folderBrowserListMinWidth - 48,
                   ideal: Theme.layout.folderBrowserListIdealWidth - 48)
        } rows: {
            ForEach(browser.visibleEntries) { entry in
                TableRow(entry)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .frame(
            minWidth: Theme.layout.folderBrowserListMinWidth,
            idealWidth: Theme.layout.folderBrowserListIdealWidth,
            maxWidth: Theme.layout.folderBrowserListMaxWidth,
            maxHeight: .infinity
        )
        .layoutPriority(0)
    }

    func fullPlainFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(
            sortedTableRows(browser),
            selection: Binding(
                get: { browser.selectedPaths },
                set: { browser.selectMany($0) }
            ),
            sortOrder: $fileTableSortOrder
        ) {
            TableColumn("Name", sortUsing: FolderTableSort(field: .name)) { (row: FolderBrowserRow) in
                fileNameCell(row.entry)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Kind", sortUsing: FolderTableSort(field: .kind)) { (row: FolderBrowserRow) in
                Text(row.kindLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Size", sortUsing: FolderTableSort(field: .size)) { (row: FolderBrowserRow) in
                Text(byteCountString(row.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)

            TableColumn("Modified", sortUsing: FolderTableSort(field: .modified)) { (row: FolderBrowserRow) in
                Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .onChange(of: fileTableSortOrder) { _, order in
            syncSortOrder(order, into: browser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func fullPinnedFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(
            sortedTableRows(browser),
            selection: Binding(
                get: { browser.selectedPaths },
                set: { browser.selectMany($0) }
            ),
            sortOrder: $fileTableSortOrder
        ) {
            TableColumn("Name", sortUsing: FolderTableSort(field: .name)) { (row: FolderBrowserRow) in
                fileNameCell(row.entry)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Pin", sortUsing: FolderTableSort(field: .pin)) { (row: FolderBrowserRow) in
                pinCell(for: row.entry)
            }
            .width(min: 44, ideal: 52, max: 64)

            TableColumn("Kind", sortUsing: FolderTableSort(field: .kind)) { (row: FolderBrowserRow) in
                Text(row.kindLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Size", sortUsing: FolderTableSort(field: .size)) { (row: FolderBrowserRow) in
                Text(byteCountString(row.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)

            TableColumn("Modified", sortUsing: FolderTableSort(field: .modified)) { (row: FolderBrowserRow) in
                Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .onChange(of: fileTableSortOrder) { _, order in
            syncSortOrder(order, into: browser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tableRows(_ browser: FolderProjectBrowserModel) -> [FolderBrowserRow] {
        browser.filteredEntries.map { entry in
            FolderBrowserRow(
                entry: entry,
                isPinned: browser.pinnedRelativePaths.contains(entry.relativePath)
            )
        }
    }

    /// Table does not reliably re-order custom-cell rows from `sortOrder` alone —
    /// sort explicitly so header clicks always regroup the listing.
    private func sortedTableRows(_ browser: FolderProjectBrowserModel) -> [FolderBrowserRow] {
        tableRows(browser).sorted(using: fileTableSortOrder)
    }

    private func syncSortOrder(_ order: [FolderTableSort],
                               into browser: FolderProjectBrowserModel) {
        guard let first = order.first else { return }
        browser.sortAscending = first.order == .forward
        switch first.field {
        case .name: browser.sortColumn = .name
        case .pin: browser.sortColumn = .pinned
        case .kind: browser.sortColumn = .kind
        case .size: browser.sortColumn = .size
        case .modified: browser.sortColumn = .modified
        }
    }

    private func fileNameCell(_ entry: FolderFileEntry) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text(entry.relativePath)
                .font(Theme.typography.monoSmall)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityLabel(entry.relativePath)
    }

    private func pinCell(for entry: FolderFileEntry) -> some View {
        let pinned = (model.folderPinnedPathsByProject[project.path] ?? []).contains(entry.relativePath)
        let pinLimitReached = (model.folderPinnedPathsByProject[project.path] ?? []).count
            >= FolderViewState.maxPinnedPaths
        return Button {
            if pinned {
                model.unpinFolderPath(entry.relativePath, in: project.path)
            } else {
                model.pinFolderPath(entry.relativePath, in: project.path)
            }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .imageScale(.small)
                .foregroundStyle(pinned ? Theme.text.primary : Theme.text.tertiary)
        }
        .buttonStyle(.plain)
        .help(pinned ? "Unpin from Sidebar" : "Pin to Sidebar")
        .accessibilityLabel(
            pinned
                ? "Unpin \(entry.relativePath) from sidebar"
                : "Pin \(entry.relativePath) to sidebar"
        )
        .disabled(!pinned && pinLimitReached)
        .onHover { DesktopActions.setPointingHandCursor($0) }
    }

    @ViewBuilder
    private func rowContextMenu(paths: Set<String>, browser: FolderProjectBrowserModel) -> some View {
        if paths.count > 1 {
            Button("Copy Paths") {
                let joined = paths.sorted().map { browser.absoluteURL(for: $0).path }.joined(separator: "\n")
                DesktopActions.copyToPasteboard(joined)
            }
            .accessibilityLabel("Copy selected paths")
            Button("Reveal in Finder") {
                for path in paths {
                    DesktopActions.revealInFinder(browser.absoluteURL(for: path))
                }
            }
            .accessibilityLabel("Reveal selected files in Finder")
        } else if let path = paths.first {
            Button("Open in Default App") {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Open \(path) in default app")
            Button("Reveal in Finder") {
                DesktopActions.revealInFinder(browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Reveal \(path) in Finder")
            Button("Copy Path") {
                DesktopActions.copyToPasteboard(browser.absoluteURL(for: path).path)
            }
            .accessibilityLabel("Copy path \(path)")
            Button("Quick Look") {
                quickLook(url: browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Quick Look \(path)")
            if kind.supportsPinnedSidebarEntries {
                Divider()
                let pins = model.folderPinnedPathsByProject[project.path] ?? []
                if pins.contains(path) {
                    Button("Unpin from Sidebar") {
                        model.unpinFolderPath(path, in: project.path)
                    }
                    .accessibilityLabel("Unpin \(path) from sidebar")
                } else {
                    Button("Pin to Sidebar") {
                        model.pinFolderPath(path, in: project.path)
                    }
                    .disabled(pins.count >= FolderViewState.maxPinnedPaths)
                    .accessibilityLabel("Pin \(path) to sidebar")
                }
            }
        }
    }
}

/// Table row wrapper with stored sort keys (computed key paths break Table sorting).
/// Non-private (matches `FolderTableSort`): `SortComparator.compare` must be at
/// least as visible as its parameter type.
struct FolderBrowserRow: Identifiable {
    var id: String { entry.relativePath }
    let entry: FolderFileEntry
    let name: String
    let kindLabel: String
    let byteCount: Int
    let modifiedAt: Date
    /// Pinned sorts before unpinned under ascending order.
    let pinSortKey: Int

    init(entry: FolderFileEntry, isPinned: Bool) {
        self.entry = entry
        self.name = entry.relativePath
        self.kindLabel = entry.kindLabel
        self.byteCount = entry.byteCount
        self.modifiedAt = entry.modifiedAt
        self.pinSortKey = isPinned ? 0 : 1
    }
}

/// Explicit comparator so column-header clicks update a typed field (not opaque key paths).
/// Non-private: `FolderProjectBrowserView` stores `[FolderTableSort]` as its sort-order state.
struct FolderTableSort: SortComparator, Hashable {
    enum Field: Hashable {
        case name
        case pin
        case kind
        case size
        case modified
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FolderBrowserRow, _ rhs: FolderBrowserRow) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .pin:
            if lhs.pinSortKey == rhs.pinSortKey {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.pinSortKey < rhs.pinSortKey ? .orderedAscending : .orderedDescending
            }
        case .kind:
            result = lhs.kindLabel.localizedStandardCompare(rhs.kindLabel)
        case .size:
            if lhs.byteCount == rhs.byteCount {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.byteCount < rhs.byteCount ? .orderedAscending : .orderedDescending
            }
        case .modified:
            if lhs.modifiedAt == rhs.modifiedAt {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
            }
        }
        return order == .forward ? result : Self.reversed(result)
    }

    private static func reversed(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
