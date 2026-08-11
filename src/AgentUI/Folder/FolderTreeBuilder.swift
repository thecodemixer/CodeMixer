import Foundation
import AgentCore

/// Builds and filters a folder hierarchy from a flat `FolderScanner` listing.
enum FolderTreeBuilder {
    /// Attaches entries by parent relative path. Directories sort before files,
    /// then `localizedStandardCompare`. Orphan paths promote to the nearest
    /// represented ancestor (or root).
    static func build(entries: [FolderFileEntry]) -> [FolderTreeNode] {
        var byPath: [String: FolderFileEntry] = [:]
        for entry in entries {
            byPath[entry.relativePath] = entry
        }

        var childrenByParent: [String: [FolderFileEntry]] = [:]
        var roots: [FolderFileEntry] = []

        for entry in entries {
            let parent = FolderFileSupport.parentRelativePath(of: entry.relativePath)
            if parent.isEmpty {
                roots.append(entry)
                continue
            }
            if byPath[parent] != nil {
                childrenByParent[parent, default: []].append(entry)
            } else {
                // Malformed/orphan: climb until a represented ancestor, else root.
                var climb = parent
                var attached = false
                while !climb.isEmpty {
                    if byPath[climb] != nil {
                        childrenByParent[climb, default: []].append(entry)
                        attached = true
                        break
                    }
                    climb = FolderFileSupport.parentRelativePath(of: climb)
                }
                if !attached {
                    roots.append(entry)
                }
            }
        }

        func node(for entry: FolderFileEntry) -> FolderTreeNode {
            let kids = sorted(childrenByParent[entry.relativePath] ?? []).map(node(for:))
            return FolderTreeNode(entry: entry, children: kids)
        }

        return sorted(roots).map(node(for:))
    }

    /// Keeps matching files and their ancestor directories. Drop empty directories
    /// that have no surviving descendant.
    static func pruned(_ nodes: [FolderTreeNode],
                       keepingFiles matches: (FolderFileEntry) -> Bool) -> [FolderTreeNode] {
        nodes.compactMap { prune($0, keepingFiles: matches) }
    }

    private static func prune(_ node: FolderTreeNode,
                              keepingFiles matches: (FolderFileEntry) -> Bool) -> FolderTreeNode? {
        if node.entry.isDirectory {
            let kids = node.children.compactMap { prune($0, keepingFiles: matches) }
            guard !kids.isEmpty else { return nil }
            return FolderTreeNode(entry: node.entry, children: kids)
        }
        return matches(node.entry) ? node : nil
    }

    private static func sorted(_ entries: [FolderFileEntry]) -> [FolderFileEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
