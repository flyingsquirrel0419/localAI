import Foundation

public enum RuntimeCommand: Sendable, Equatable {
    case node(script: String, args: [String])
    case npm(args: [String])
}

public enum RuntimeEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(code: Int32, duration: TimeInterval)
}

public enum RuntimeError: Error, Equatable, Sendable {
    case timedOut(seconds: Int)
    case launchFailed(String)
    case executableNotFound(String)
}

extension RuntimeError: UserFacingErrorConvertible {
    public var userFacingError: UserFacingError {
        switch self {
        case .timedOut(let seconds):
            return UserFacingError(
                title: "Command timed out",
                message: "The command was stopped after \(seconds) seconds.",
                recoveryAction: .retry,
                developerDetails: "timedOut \(seconds)s"
            )
        case .launchFailed(let detail):
            return UserFacingError(
                title: "Could not run command",
                message: "The Node.js command couldn't be started.",
                recoveryAction: .retry,
                developerDetails: SecretRedactor.redact(detail)
            )
        case .executableNotFound(let name):
            return UserFacingError(
                title: "Runtime unavailable",
                message: "\"\(name)\" isn't available in this runtime.",
                recoveryAction: .dismiss,
                developerDetails: "executableNotFound: \(name)"
            )
        }
    }
}

/// Runs Node/npm commands, streaming output. iOS implementation will target
/// NodeMobile when available; desktop/tests use ProcessJavaScriptRuntime.
public protocol JavaScriptRuntimeService: Sendable {
    /// Run a command in `directory`. The stream emits stdout/stderr chunks as
    /// they arrive and finishes with `.exited`. Cancelling the consuming task
    /// kills the child process.
    func run(
        _ command: RuntimeCommand,
        in directory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> AsyncThrowingStream<RuntimeEvent, Error>
}

/// Scans a package directory for indicators that it requires a native Node
/// addon — something the mobile JS runtime cannot provide.
public struct NativeAddonDetector: Sendable {
    /// Packages known to ship/compile native code.
    public static let knownNativePackages: Set<String> = [
        "node-gyp", "bcrypt", "sqlite3", "sharp", "canvas", "better-sqlite3",
        "fsevents", "node-sass", "grpc", "ref", "ffi-napi", "node-pty",
        "utf-8-validate", "bufferutil", "kerberos", "cpu-features"
    ]

    public static let userMessage =
        "This package requires a native Node addon that is not supported by the current mobile runtime."

    public init() {}

    /// Packages in `directory` that look native. Returns an empty array if none.
    public func detectNativePackages(in directory: URL) -> [String] {
        var found: [String] = []
        let fm = FileManager.default

        // 1. package.json at root: gypfile flag or known-native deps.
        let packageURL = directory.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (root["gypfile"] as? Bool) == true {
                if let name = root["name"] as? String { found.append(name) }
            }
            for section in ["dependencies", "devDependencies", "optionalDependencies"] {
                if let deps = root[section] as? [String: Any] {
                    for name in deps.keys where Self.knownNativePackages.contains(name) {
                        found.append(name)
                    }
                }
            }
        }

        // 2. binding.gyp at root.
        if fm.fileExists(atPath: directory.appendingPathComponent("binding.gyp").path) {
            if let data = try? Data(contentsOf: packageURL),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = root["name"] as? String {
                found.append(name)
            } else {
                found.append(directory.lastPathComponent)
            }
        }

        // 3. node_modules: *.node binaries, binding.gyp, or gypfile manifests.
        let modulesDir = directory.appendingPathComponent("node_modules")
        if let topLevel = try? fm.contentsOfDirectory(atPath: modulesDir.path) {
            for entry in topLevel {
                let pkgDir = modulesDir.appendingPathComponent(entry)
                if entry.hasPrefix("@") {
                    // Scoped packages: descend one level.
                    if let scoped = try? fm.contentsOfDirectory(atPath: pkgDir.path) {
                        for child in scoped {
                            let name = "\(entry)/\(child)"
                            if Self.packageLooksNative(pkgDir.appendingPathComponent(child)) {
                                found.append(name)
                            }
                        }
                    }
                } else if Self.packageLooksNative(pkgDir) {
                    found.append(entry)
                }
            }
        }

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }.sorted()
    }

    private static func packageLooksNative(_ packageDirectory: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageDirectory.appendingPathComponent("binding.gyp").path) {
            return true
        }
        let manifestURL = packageDirectory.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: manifestURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if (json["gypfile"] as? Bool) == true { return true }
            if let name = json["name"] as? String, knownNativePackages.contains(name) { return true }
        }
        // *.node prebuilt binaries anywhere in the package directory.
        if let enumerator = fm.enumerator(atPath: packageDirectory.path) {
            for case let file as String in enumerator where file.hasSuffix(".node") {
                return true
            }
        }
        return false
    }
}
