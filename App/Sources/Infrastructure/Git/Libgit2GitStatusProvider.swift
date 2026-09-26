import Foundation
import LocalAICore

/// `GitStatusProvider` backed by `Libgit2GitService`. Returns the set of
/// worktree-relative paths with any unstaged or staged changes (M/A/D/U/R).
public struct Libgit2GitStatusProvider: GitStatusProvider {
    private let service: Libgit2GitService

    public init(service: Libgit2GitService) {
        self.service = service
    }

    public func modifiedPaths(workspace: URL) async -> Set<String> {
        guard await service.isGitRepository(at: workspace) else { return [] }
        do {
            let entries = try await service.status(in: workspace)
            return Set(entries.map { $0.path })
        } catch {
            return []
        }
    }
}
