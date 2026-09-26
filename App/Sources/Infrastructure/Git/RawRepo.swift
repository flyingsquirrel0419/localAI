import Foundation
import Git2 // re-exports Cgit2

/// Minimal raw-libgit2 helper for the operations the Git2 Swift wrapper at the
/// pinned commit does not yet expose: index↔workdir diff, tree→index diff,
/// diff→unified-text, `git_reset_default` for unstage, and path-scoped
/// `git_checkout_head` for revert.
///
/// A `RawRepo` opens its own `git_repository*` handle against the same
/// directory as the Swift wrapper's ``Repository``. libgit2 supports multiple
/// open handles per on-disk repo; each keeps its own index cache. We call
/// `git_index_read` after opening to ensure the raw handle sees the latest
/// on-disk index state.
final class RawRepo {
    struct Error: Swift.Error {
        let message: String
    }

    private let handle: OpaquePointer

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    static func open(_ directory: URL) throws -> RawRepo {
        var raw: OpaquePointer?
        let rc: Int32 = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return GIT_EINVALIDSPEC.rawValue }
            return git_repository_open(&raw, path)
        }
        guard rc == 0, let raw else {
            throw Error(message: lastErrorMessage(fallback: "open failed (\(rc))"))
        }
        return RawRepo(handle: raw)
    }

    func close() {
        git_repository_free(handle)
    }

    static func lastErrorMessage(fallback: String) -> String {
        guard let err = git_error_last(), let msg = err.pointee.message else {
            return fallback
        }
        return String(cString: msg)
    }

    // MARK: - Diff (unified text)

    /// Produce a unified diff string.
    /// - `staged == false`: index → workdir (uncommitted, unstaged changes).
    /// - `staged == true`:  HEAD tree → index (staged changes).
    func unifiedDiff(paths: [String]?, staged: Bool) throws -> String {
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.context_lines = 3

        // Pathspec bridging: keep the CStrings alive for the duration of the diff.
        var cStrings: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for p in cStrings { free(p) }
        }
        if let paths, !paths.isEmpty {
            cStrings = paths.map { strdup($0) }
            var strArr = git_strarray()
            cStrings.withUnsafeMutableBufferPointer { buf in
                strArr.strings = buf.baseAddress
                strArr.count = buf.count
            }
            opts.pathspec = strArr
        }

        var diffRaw: OpaquePointer?
        let rc: Int32

        if staged {
            // Resolve HEAD to a tree (nil on unborn HEAD = empty tree).
            var headObjRaw: OpaquePointer?
            var headTreeRaw: OpaquePointer?
            defer {
                if let h = headObjRaw { git_object_free(h) }
                if let t = headTreeRaw { git_tree_free(t) }
            }
            if git_revparse_ext(&headObjRaw, nil, handle, "HEAD") == 0, let headObj = headObjRaw {
                _ = git_object_peel(&headTreeRaw, headObj, GIT_OBJECT_TREE)
            }

            var indexRaw: OpaquePointer?
            guard git_repository_index(&indexRaw, handle) == 0, let indexRaw else {
                throw Error(message: "could not open index")
            }
            defer { git_index_free(indexRaw) }
            // Re-read so the raw handle sees the latest on-disk state.
            git_index_read(indexRaw, 1)

            rc = git_diff_tree_to_index(&diffRaw, handle, headTreeRaw, indexRaw, &opts)
        } else {
            var indexRaw: OpaquePointer?
            guard git_repository_index(&indexRaw, handle) == 0, let indexRaw else {
                throw Error(message: "could not open index")
            }
            defer { git_index_free(indexRaw) }
            git_index_read(indexRaw, 1)

            rc = git_diff_index_to_workdir(&diffRaw, handle, indexRaw, &opts)
        }

        guard rc == 0, let diffRaw else {
            throw Error(message: Self.lastErrorMessage(fallback: "diff failed (\(rc))"))
        }
        defer { git_diff_free(diffRaw) }

        var buf = git_buf()
        defer { git_buf_dispose(&buf) }
        let toBufRC = git_diff_to_buf(&buf, diffRaw, GIT_DIFF_FORMAT_PATCH)
        guard toBufRC == 0 else {
            throw Error(message: Self.lastErrorMessage(fallback: "git_diff_to_buf failed"))
        }
        guard let ptr = buf.ptr else { return "" }
        return String(cString: ptr)
    }

    // MARK: - Unstage

    /// `git reset HEAD -- <path>` — drops the index entry back to HEAD.
    /// On unborn HEAD, removes the entry from the index entirely.
    func unstagePath(_ path: String) throws {
        var headObj: OpaquePointer?
        let headRC = git_revparse_ext(&headObj, nil, handle, "HEAD")

        if headRC != 0 || headObj == nil {
            // Unborn: just drop the entry from the index.
            var indexRaw: OpaquePointer?
            guard git_repository_index(&indexRaw, handle) == 0, let indexRaw else { return }
            defer { git_index_free(indexRaw) }
            git_index_read(indexRaw, 1)
            _ = path.withCString { git_index_remove_bypath(indexRaw, $0) }
            git_index_write(indexRaw)
            return
        }
        defer { git_object_free(headObj) }

        let cStr = strdup(path)
        defer { free(cStr) }
        var mutable: UnsafeMutablePointer<CChar>? = cStr
        var strArr = git_strarray()
        withUnsafeMutablePointer(to: &mutable) { ptr in
            strArr.strings = ptr
            strArr.count = 1
        }
        var copy = strArr
        let rc = git_reset_default(handle, headObj, &copy)
        guard rc == 0 else {
            throw Error(message: Self.lastErrorMessage(fallback: "unstage failed (\(rc))"))
        }
    }

    // MARK: - Revert single path from HEAD

    /// `git checkout HEAD -- <path>` — restore working-tree contents from HEAD.
    /// Rejects paths containing `..` or starting with `/` to keep the
    /// operation inside the working tree.
    func checkoutPathFromHead(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw Error(message: "invalid path: \(path)")
        }
        var opts = git_checkout_options()
        git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue

        let cStr = strdup(path)
        defer { free(cStr) }
        var mutable: UnsafeMutablePointer<CChar>? = cStr
        var strArr = git_strarray()
        withUnsafeMutablePointer(to: &mutable) { ptr in
            strArr.strings = ptr
            strArr.count = 1
        }
        opts.paths = strArr

        let rc = git_checkout_head(handle, &opts)
        guard rc == 0 else {
            throw Error(message: Self.lastErrorMessage(fallback: "checkout failed (\(rc))"))
        }
    }

    // MARK: - Unborn HEAD symbolic target

    /// When HEAD is unborn, read its symbolic target's short name
    /// (e.g. `"main"` from `refs/heads/main`).
    func unbornHeadBranch() -> String? {
        var headRaw: OpaquePointer?
        guard git_repository_head(&headRaw, handle) == 0, let headRaw else { return nil }
        defer { git_reference_free(headRaw) }
        guard git_reference_type(headRaw) == GIT_REFERENCE_SYMBOLIC,
              let target = git_reference_symbolic_target(headRaw) else { return nil }
        let name = String(cString: target)
        if name.hasPrefix("refs/heads/") {
            return String(name.dropFirst("refs/heads/".count))
        }
        return nil
    }
}
