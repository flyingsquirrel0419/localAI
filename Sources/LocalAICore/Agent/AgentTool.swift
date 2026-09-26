import Foundation

/// A declared tool: name + JSON-schema-like parameter description used in the
/// system prompt so a small model can emit calls in a fixed format.
public struct AgentTool: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let parameters: [Parameter]

    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let type: String   // "string", "integer", "boolean", "array", "object"
        public let required: Bool
        public let description: String

        public init(name: String, type: String, required: Bool, description: String) {
            self.name = name
            self.type = type
            self.required = required
            self.description = description
        }
    }

    public init(name: String, summary: String, parameters: [Parameter]) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
    }

    /// Render the schema in a compact prompt-friendly form.
    public func promptDescription() -> String {
        var out = "- \(name): \(summary)\n  params: {"
        let parts = parameters.map { p -> String in
            let req = p.required ? "" : "?"
            return "\(p.name)\(req):\(p.type)"
        }
        out += parts.joined(separator: ", ")
        out += "}"
        return out
    }
}

/// Registry of the tools the agent can call.
public enum AgentTools {
    public static let all: [AgentTool] = [
        AgentTool(name: "list_directory", summary: "List files and folders at a path.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative directory path, \".\" for root")
        ]),
        AgentTool(name: "read_file", summary: "Read a UTF-8 text file.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative file path"),
            .init(name: "startLine", type: "integer", required: false, description: "First line (1-based)"),
            .init(name: "endLine", type: "integer", required: false, description: "Last line, inclusive")
        ]),
        AgentTool(name: "write_file", summary: "Overwrite an existing file with new contents.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative file path"),
            .init(name: "contents", type: "string", required: true, description: "Full new contents")
        ]),
        AgentTool(name: "create_file", summary: "Create a new file; fails if it already exists.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative file path"),
            .init(name: "contents", type: "string", required: false, description: "Initial contents")
        ]),
        AgentTool(name: "delete_file", summary: "Delete a file. Deleting a directory requires confirmation.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative path")
        ]),
        AgentTool(name: "move_file", summary: "Move or rename a file or directory.", parameters: [
            .init(name: "source", type: "string", required: true, description: "Current relative path"),
            .init(name: "destination", type: "string", required: true, description: "New relative path")
        ]),
        AgentTool(name: "search_files", summary: "Find files by name.", parameters: [
            .init(name: "query", type: "string", required: true, description: "Name substring"),
            .init(name: "extensions", type: "array", required: false, description: "Filter extensions, e.g. [\"ts\"]")
        ]),
        AgentTool(name: "search_text", summary: "Search file contents.", parameters: [
            .init(name: "pattern", type: "string", required: true, description: "Text or regex"),
            .init(name: "isRegex", type: "boolean", required: false, description: "Interpret pattern as regex"),
            .init(name: "extensions", type: "array", required: false, description: "Filter extensions")
        ]),
        AgentTool(name: "apply_patch", summary: "Apply a unified diff to files.", parameters: [
            .init(name: "diff", type: "string", required: true, description: "Unified diff text")
        ]),
        AgentTool(name: "edit_file", summary: "Replace one unique string in a file.", parameters: [
            .init(name: "path", type: "string", required: true, description: "Relative file path"),
            .init(name: "old_string", type: "string", required: true, description: "Exact existing text, must occur once"),
            .init(name: "new_string", type: "string", required: true, description: "Replacement text")
        ]),
        AgentTool(name: "run_node", summary: "Run a Node.js script.", parameters: [
            .init(name: "script", type: "string", required: true, description: "Script path relative to repo root"),
            .init(name: "args", type: "array", required: false, description: "Extra CLI args"),
            .init(name: "timeoutSeconds", type: "integer", required: false, description: "Kill after N seconds")
        ]),
        AgentTool(name: "run_npm", summary: "Run an npm command, e.g. args=[\"test\"].", parameters: [
            .init(name: "args", type: "array", required: true, description: "npm CLI args"),
            .init(name: "timeoutSeconds", type: "integer", required: false, description: "Kill after N seconds")
        ]),
        AgentTool(name: "git_clone", summary: "Clone a repository into a subdirectory.", parameters: [
            .init(name: "url", type: "string", required: true, description: "Repo URL"),
            .init(name: "directory", type: "string", required: true, description: "Target directory name"),
            .init(name: "branch", type: "string", required: false, description: "Branch to clone")
        ]),
        AgentTool(name: "git_status", summary: "Show working tree status.", parameters: []),
        AgentTool(name: "git_diff", summary: "Show a unified diff.", parameters: [
            .init(name: "paths", type: "array", required: false, description: "Restrict to these paths"),
            .init(name: "staged", type: "boolean", required: false, description: "Diff the index")
        ]),
        AgentTool(name: "git_add", summary: "Stage paths.", parameters: [
            .init(name: "paths", type: "array", required: true, description: "Paths to stage")
        ]),
        AgentTool(name: "git_commit", summary: "Commit staged changes.", parameters: [
            .init(name: "message", type: "string", required: true, description: "Commit message")
        ]),
        AgentTool(name: "git_pull", summary: "Pull (fast-forward only) from origin.", parameters: []),
        AgentTool(name: "git_push", summary: "Push the current branch. Requires the user to have explicitly asked to push.", parameters: [
            .init(name: "remote", type: "string", required: false, description: "Remote name, default origin"),
            .init(name: "branch", type: "string", required: false, description: "Branch, default current")
        ]),
        AgentTool(name: "git_branch", summary: "List branches or create/switch.", parameters: [
            .init(name: "create", type: "string", required: false, description: "Create branch with this name"),
            .init(name: "checkout", type: "string", required: false, description: "Switch to this branch")
        ]),
        AgentTool(name: "get_project_info", summary: "Package.json name/scripts/deps, top-level tree, current git branch.", parameters: [])
    ]

    public static let byName: [String: AgentTool] = {
        var map: [String: AgentTool] = [:]
        for tool in all { map[tool.name] = tool }
        return map
    }()
}
