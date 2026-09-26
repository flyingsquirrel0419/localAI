# LocalAI

An iOS app that pairs a small on-device LLM (via MLX) with a coding-agent
loop, an in-process Node.js runtime, and git, so the model can read, edit,
and test a repository on your phone or tablet.

Status: **work-in-progress**. The core agent loop, NodeHost, git, and tool
execution are tested on Linux and macOS CI. **Nothing has been verified on a
real device yet** — see *Known limitations* below before relying on this.

## Screens

- **Login** — GitHub OAuth device flow (or personal access token) for cloning
  and pushing.
- **Agent** — the chat-style agent: ask for a change, the model emits
  `<tool_call>{...}</tool_call>` JSON, the app executes tools and streams
  results back into the conversation. Supports stop, resume-from-checkpoint,
  and a per-run file-change summary.
- **Code** — browse and edit the checked-out repo on top of the agent's
  sandboxed file system.
- **Models** — browse Hugging Face, download MLX safetensors models, delete,
  and manage cache.

## Architecture

```
App/                              iOS app target (SwiftUI)
  Sources/Features/               Login, Agent, CodeBrowser, Models
  Sources/Services/               MLXEngine (mlx-swift-lm), GitHub auth,
                                  ModelService, ChangeTracker, CodeService
  Sources/Infrastructure/
    Git/                          GitService protocol + CLIGitService (macOS,
                                  dev) + Libgit2GitService (iOS, via
                                  libgit2.swift) + RawRepo C-git2 helpers
    Node/                         NodeMobileLauncher (spawns NodeHost inside
                                  nodejs-mobile), NodeHostJavaScriptRuntime
Sources/LocalAICore/              Portable Swift package (Linux-tested)
  Agent/                          AgentLoop, ToolCallParser, ToolExecutor,
                                  PushIntentDetector, ContextWindowManager
  HuggingFace/                    ModelDownloader (resumable), ModelStore
  Node/                           NodeHostJavaScriptRuntime (client),
                                  ProcessNodeHostLauncher (dev/test on
                                  macOS/Linux)
  Security/                       SandboxedFileSystem, SecretRedactor
NodeHost/                         Node 18 JS host run inside nodejs-mobile
  host.js                         Long-lived TCP 127.0.0.1 server
  lib/                            worker (worker_threads), runner, tar,
                                  shellwords, child-shim
  npm/                            In-process npm emulation: run/install
```

The agent never shells out; every tool (`read_file`, `edit_file`,
`git_commit`, `run_node`, …) is a Swift function behind a sandboxed file
system or the git service.

## Requirements

- Xcode 26 on macOS 15+ to build the app.
- An iOS 17+ device with an Apple GPU (A14 / M1 or later recommended). MLX
  **does not run in the Simulator**; you must deploy to a real device.
- The app requests the `increased-memory-limit` entitlement — needed for
  multi-GB models.
- NodeMobile.xcframework (see *Build*). CI and the local script download it;
  it is not committed to the repo.

## Build

```bash
# 1. Fetch the NodeMobile xcframework (~51 MB download).
scripts/fetch-nodemobile.sh

# 2. Generate the Xcode project.
cd App && xcodegen

# 3. Build for a device (NOT the Simulator — MLX needs a GPU).
xcodebuild -project App/LocalAI.xcodeproj \
  -scheme LocalAI -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For the core package alone (no Xcode needed):

```bash
swift build && swift test
```

## Model support

- **MLX safetensors** models from Hugging Face, loaded through
  [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.31.4. The
  downloader is resumable (HTTP Range + `.partial` files).
- GGUF / llama.cpp models are **not yet** supported.
- A 4-bit 3B–4B model is the practical ceiling for a phone; the agent system
  prompt is tuned for small models (short, imperative, one tool call per turn,
  explicit stop sequences).

## Git

- iOS uses [libgit2.swift](https://github.com/k-ymmt/libgit2.swift), pinned to
  a specific revision (no tagged release yet ships the Swift target).
- Auth is HTTPS + token (GitHub PAT or OAuth token) supplied via the libgit2
  credential callback. Tokens are **never** embedded in remote URLs; existing
  credentialed remotes are scrubbed on open.
- Pull is fast-forward only. **Force push is never authorized**, and the
  push-intent detector requires an explicit user request ("push", "푸시해줘")
  before `git_push` is allowed to run.

## Node runtime (NodeHost)

The app embeds [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)
v18.20.4 and runs one long-lived Node process (`NodeHost/host.js`) that
accepts newline-delimited-JSON commands over a 127.0.0.1 TCP socket guarded by
a 32-byte random token. Every `node script.js` / `npm run …` from the agent
is dispatched into a `worker_threads` Worker.

Limitations of this setup:

- nodejs-mobile is **Node 18, JIT-less**. Anything depending on V8 codegen
  (some regexes, `eval`-heavy libraries) is slow or broken.
- `child_process` is unavailable — `spawn`/`exec` throw, except
  `node file.js`, which is emulated with a nested worker.
- **No native addons.** `node-gyp` builds never run.
- **No install scripts.** `npm install` downloads and extracts tarballs but
  never runs `preinstall`/`install`/`postinstall`. Packages that need them
  (esbuild, sharp, esbuild-style shims) will fail at require time.
- jest / vitest / mocha and other test runners with heavy worker or ESM
  requirements generally **don't work**; the in-repo fixture tests use
  plain `node --test`.
- Only **one** NodeHost instance runs per app process (nodejs-mobile's
  `node_start()` is single-shot).
- File access from JS is the **app container's**, not a separate sandbox.
  The agent-facing tools are confined to the workspace, but JavaScript code
  you run can read anything the app itself can — treat `run_node` /
  `run_npm` as trusted-but-unprivileged, not as a security boundary.

## Security

- **Token handling.** Git tokens live in the Keychain, are passed to libgit2
  through the credential callback only, and are redacted from tool output,
  logs, and error messages (known-secrets + shape patterns: `ghp_`, `hf_`,
  `glpat-`, `github_pat_`, URL userinfo, labelled 40-hex).
- **Workspace confinement.** `SandboxedFileSystem` resolves every agent path
  under the repo root and rejects `..` / absolute escapes. `run_node` and
  `run_npm` scripts must resolve inside the workspace.
- **Host auth.** NodeHost refuses any request without a valid token, compared
  in constant time. An empty/missing token refuses everything.
- **Script env.** The NodeHost worker strips `LOCALAI_HOST_TOKEN`,
  `LOCALAI_HOST_PORT`, `GITHUB_TOKEN`, `HF_TOKEN`, etc. before running user
  JS — scripts never see host credentials.
- **Archive safety.** `.tgz` extraction (`npm install`) skips absolute paths,
  `..` traversal, and symlinks whose target escapes the destination.
- **Push gate.** `git_push` requires explicit user intent (matched with word
  boundaries, with force-push and negations always refusing).
- **Cancellation.** `stop()` cancels the in-flight generation and the current
  tool, and the agent loop refuses to clobber a stopped state with a
  subsequent checkpoint save.

## Testing

CI (`.github/workflows/ci.yml`) runs on every push:

- **Linux** (`swift:6.1` container): `swift build -j 2 && swift test -j 2`
  against `LocalAICore`, plus the NodeHost tests under `node --test`.
- **macOS 15** (Xcode 26): package tests, then `xcodegen` + `xcodebuild` for
  a generic iOS device, a bundle assertion that `NodeMobile.framework` is
  embedded, and a check that the binary dynamically links NodeMobile.
- An end-to-end agent test runs a real NodeHost subprocess on Linux against
  a `ScriptedEngine` and asserts the full fix-tests → commit → push flow
  works against a real git remote.

Run the same locally:

```bash
swift build -j 2 && swift test -j 2
node --test NodeHost/test/*.test.js
```

## Known limitations

**Not verified on a real device.** In particular, the following have only
been exercised on macOS/Linux CI, not on iOS hardware:

- MLX model load, tokenization, and streaming.
- NodeMobile xcframework startup, `node_start()` bridging, and worker
  stability on device.
- libgit2 on-device behaviour (credentials, TLS, large repos).
- Background task lifecycle (iOS kills the app — the agent does not yet
  suspend/resume cleanly).
- GitHub OAuth device flow — you need to register your own OAuth app and
  paste the client ID into `App/Sources/Services/GitHubAuthService.swift`.

## Roadmap

- On-device validation pass (MLX streaming, NodeMobile, libgit2).
- GGUF / llama.cpp backend alongside MLX.
- Real-time tool-call UI (per-call status rows instead of chat bubbles).
- Smarter context-window management (file-aware eviction, persistent memory).
- Multi-workspace UI.
