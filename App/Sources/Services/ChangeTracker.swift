import Foundation
import LocalAICore

/// Snapshots file contents before edits so the Diff tab can show "what changed"
/// without requiring Git. Replaced by Git-backed diffing in a later phase.
public actor ChangeTracker {

    public struct ChangedFile: Sendable, Equatable, Identifiable {
        public let relativePath: String
        public let original: String
        public let current: String
        public var id: String { relativePath }
    }

    private var originals: [String: String] = [:]
    private var order: [String] = []

    public init() {}

    /// Snapshot the current contents of a file before an edit, if not already
    /// tracked. Idempotent — once a file is tracked we keep the original.
    public func trackBeforeEdit(relativePath: String, contents: String) {
        guard originals[relativePath] == nil else { return }
        originals[relativePath] = contents
        order.append(relativePath)
    }

    /// Snapshot a path that does not yet exist (e.g. before create).
    public func trackCreation(relativePath: String) {
        guard originals[relativePath] == nil else { return }
        originals[relativePath] = ""
        order.append(relativePath)
    }

    /// Mark a path as no longer changed (e.g. user reverted, or file deleted).
    public func clear(relativePath: String) {
        originals.removeValue(forKey: relativePath)
        order.removeAll { $0 == relativePath }
    }

    public func clearAll() {
        originals.removeAll()
        order.removeAll()
    }

    /// Compare originals against current contents on disk. Files that match
    /// their original are dropped from the result.
    public func changedFiles(fileSystem: SandboxedFileSystem) -> [ChangedFile] {
        var results: [ChangedFile] = []
        for path in order {
            guard let original = originals[path] else { continue }
            let current: String
            do {
                current = try fileSystem.read(path)
            } catch {
                // File is gone — report it as a deletion of the original.
                results.append(ChangedFile(relativePath: path, original: original, current: ""))
                continue
            }
            if current != original {
                results.append(ChangedFile(relativePath: path, original: original, current: current))
            }
        }
        return results
    }

    /// Revert a path to its original contents and stop tracking it. If the
    /// original was empty (file created during the session) and the current
    /// content exists, deletes the file.
    public func revert(relativePath: String, fileSystem: SandboxedFileSystem) throws {
        guard let original = originals[relativePath] else { return }
        if original.isEmpty && fileSystem.exists(relativePath) {
            try fileSystem.delete(relativePath, recursive: false)
        } else {
            try fileSystem.write(relativePath, contents: original)
        }
        clear(relativePath: relativePath)
    }
}

/// Stand-in for a future Git-backed modified-file provider. The current
/// implementation always returns empty until Git lands; the ChangeTracker
/// powers the actual diff list.
public protocol GitStatusProvider: Sendable {
    /// Repository-relative paths that are modified per Git.
    func modifiedPaths(workspace: URL) async -> Set<String>
}

public struct EmptyGitStatusProvider: GitStatusProvider {
    public init() {}
    public func modifiedPaths(workspace: URL) async -> Set<String> { [] }
}
