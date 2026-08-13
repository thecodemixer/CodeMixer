import Foundation
import AgentCore

/// Deterministic four-pane sizing for the focused dual-folder surface.
///
/// Outer trees start at the same ideal width and the remaining center is split
/// equally. At narrow window sizes the minimums scale down together so no pane
/// can disappear off-screen.
struct DualFolderPaneLayout: Equatable {
    static let coordinateSpaceName = "dual-folder-pane-layout"

    let availableWidth: CGFloat
    let treeMinimumWidth: CGFloat
    let previewMinimumWidth: CGFloat
    let leftTreeWidth: CGFloat
    let leftPreviewWidth: CGFloat
    let rightPreviewWidth: CGFloat
    let rightTreeWidth: CGFloat

    var previewBoundary: CGFloat { leftTreeWidth + leftPreviewWidth }
    var rightTreeBoundary: CGFloat { availableWidth - rightTreeWidth }

    static func resolve(availableWidth: CGFloat,
                        leftTreeWidth: CGFloat?,
                        rightTreeWidth: CGFloat?,
                        previewSplitFraction: CGFloat) -> Self {
        let width = max(availableWidth, 1)
        let treeMinimum = min(Theme.layout.dualFolderTreeListMinWidth, width * 0.14)
        let previewMinimum = min(Theme.layout.dualFolderPreviewMinWidth, width * 0.22)
        let maximumCombinedTrees = max(treeMinimum * 2, width - previewMinimum * 2)
        // Tree rows carry indented, extension-suffixed filenames, so the ideal
        // width is generous enough to read one without truncation.
        let idealTree = min(
            Theme.layout.dualFolderTreeListIdealWidth,
            width * 0.22,
            maximumCombinedTrees / 2
        )
        let leftTree = clamp(
            leftTreeWidth ?? idealTree,
            minimum: treeMinimum,
            maximum: maximumCombinedTrees - treeMinimum
        )
        let rightTree = clamp(
            rightTreeWidth ?? idealTree,
            minimum: treeMinimum,
            maximum: maximumCombinedTrees - leftTree
        )
        let centerWidth = max(width - leftTree - rightTree, previewMinimum * 2)
        let minimumFraction = previewMinimum / centerWidth
        let fraction = clamp(
            previewSplitFraction,
            minimum: minimumFraction,
            maximum: 1 - minimumFraction
        )
        let leftPreview = centerWidth * fraction

        return Self(
            availableWidth: width,
            treeMinimumWidth: treeMinimum,
            previewMinimumWidth: previewMinimum,
            leftTreeWidth: leftTree,
            leftPreviewWidth: leftPreview,
            rightPreviewWidth: centerWidth - leftPreview,
            rightTreeWidth: rightTree
        )
    }

    func clampedLeftTreeWidth(for boundary: CGFloat) -> CGFloat {
        Self.clamp(
            boundary,
            minimum: treeMinimumWidth,
            maximum: previewBoundary - previewMinimumWidth
        )
    }

    func clampedRightTreeWidth(for boundary: CGFloat) -> CGFloat {
        Self.clamp(
            availableWidth - boundary,
            minimum: treeMinimumWidth,
            maximum: availableWidth - previewBoundary - previewMinimumWidth
        )
    }

    func clampedPreviewFraction(for boundary: CGFloat) -> CGFloat {
        previewFraction(
            keepingBoundaryAt: boundary,
            leftTreeWidth: leftTreeWidth,
            rightTreeWidth: rightTreeWidth
        )
    }

    func previewFraction(keepingBoundaryAt boundary: CGFloat,
                         leftTreeWidth: CGFloat,
                         rightTreeWidth: CGFloat) -> CGFloat {
        let centerWidth = availableWidth - leftTreeWidth - rightTreeWidth
        guard centerWidth > 0 else { return 0.5 }
        let minimum = previewMinimumWidth / centerWidth
        return Self.clamp(
            (boundary - leftTreeWidth) / centerWidth,
            minimum: minimum,
            maximum: 1 - minimum
        )
    }

    private static func clamp(_ value: CGFloat,
                              minimum: CGFloat,
                              maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), max(minimum, maximum))
    }
}
