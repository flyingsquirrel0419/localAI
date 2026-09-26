# LocalAI — iPhone Local AI Development Workspace (MVP goals)

Product: iPhone app where a local LLM agent clones a GitHub repo, reads/edits code,
runs Node/npm, tests, shows diffs, commits and pushes. Exactly 4 screens:
Login, Agent (main), Code & Files, Models. Tabs after login: Agent | Code | Models.

## Constraints of this build environment
- Dev box is Linux x86_64 (Swift 6.1.2, 3 GB RAM, 2 cores). No Xcode, no iPhone.
- Portable logic lives in `LocalAICore` (Foundation only) and is tested on Linux with `swift test`.
- iOS-only code (SwiftUI, MLX, Keychain, libgit2, NodeMobile) lives in `App/` and is
  built by GitHub Actions on macOS runners (XcodeGen + xcodebuild, iOS Simulator).
- Real-device E2E acceptance (README §38) cannot be executed here; it must be run by a human.

## Session goals (definition of done)
G1 Public GitHub repo, CI green (Linux `swift test` + macOS iOS build).
G2 LocalAICore: workspace store, sandboxed filesystem (path traversal protection), search
   (.gitignore, default excludes), unified diff + patch apply, HF URL parser, HF metadata
   client, compatibility estimate, resumable downloader, agent loop with typed tools,
   limits/timeout/cancellation, checkpoints/task state, credential store protocol,
   GitService / JavaScriptRuntimeService / LocalModelEngine protocols. All unit-tested.
G3 iOS app: 4 screens wired to real services (no fake UI): HF token login + GitHub PAT
   login (Keychain), model URL → metadata → download → MLX load → streaming chat,
   Code tab (tree, editor, diff), Agent tab driving the agent loop with MLX engine.
G4 Git on iOS via libgit2 wrapper; Node via NodeMobile if it builds, else documented limitation.
G5 README honest about what works and what is unverified on device.
