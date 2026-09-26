import Foundation

public enum ModelFormat: String, Sendable, Equatable, Codable {
    case mlx
    case gguf
    case unknown
}

public enum CompatibilityVerdict: Sendable, Equatable {
    case compatible
    /// Estimated memory exceeds 60% of device RAM.
    case mayNotRunReliably(estimatedBytes: Int64, deviceRAMBytes: Int64)
    /// GGUF is recognized but not loadable by this build.
    case unsupportedFormat(reason: String)
    /// Not enough free storage for the download.
    case insufficientStorage(neededBytes: Int64, availableBytes: Int64)
}

public struct ModelCompatibilityReport: Sendable, Equatable {
    public let format: ModelFormat
    public let architecture: String?
    public let quantizationBits: Int?
    public let parameterCountBillions: Double?
    public let downloadBytes: Int64
    public let estimatedMemoryBytes: Int64
    public let verdict: CompatibilityVerdict
}

/// Derives a compatibility estimate from HF model metadata. Pure function of
/// its inputs so it is trivially testable.
public enum ModelCompatibility {
    /// - Parameters:
    ///   - info: HF model metadata.
    ///   - deviceRAMBytes: physical memory of the device.
    ///   - availableStorageBytes: free disk space.
    public static func evaluate(
        info: HFModelInfo,
        deviceRAMBytes: Int64,
        availableStorageBytes: Int64
    ) -> ModelCompatibilityReport {
        let format = detectFormat(info: info)
        let quantBits = detectQuantizationBits(info: info)
        let params = detectParameterCount(info: info)
        let downloadBytes = neededFileBytes(info: info, format: format)
        // Weights dominate memory; add ~20% overhead + 0.5 GB runtime headroom.
        let estimatedMemory = Int64(Double(downloadBytes) * 1.2) + 512 * 1024 * 1024

        let verdict: CompatibilityVerdict
        if format == .gguf {
            verdict = .unsupportedFormat(reason: "GGUF models are not supported in this version")
        } else if downloadBytes > availableStorageBytes {
            verdict = .insufficientStorage(neededBytes: downloadBytes, availableBytes: availableStorageBytes)
        } else if estimatedMemory > Int64(Double(deviceRAMBytes) * 0.6) {
            verdict = .mayNotRunReliably(estimatedBytes: estimatedMemory, deviceRAMBytes: deviceRAMBytes)
        } else {
            verdict = .compatible
        }

        return ModelCompatibilityReport(
            format: format,
            architecture: info.modelType,
            quantizationBits: quantBits,
            parameterCountBillions: params,
            downloadBytes: downloadBytes,
            estimatedMemoryBytes: estimatedMemory,
            verdict: verdict
        )
    }

    // MARK: - Detection helpers

    static func detectFormat(info: HFModelInfo) -> ModelFormat {
        if info.siblings.contains(where: { $0.path.hasSuffix(".gguf") }) {
            return .gguf
        }
        let loweredTags = info.tags.map { $0.lowercased() }
        if loweredTags.contains("mlx") || info.libraryName?.lowercased() == "mlx" {
            return .mlx
        }
        if info.siblings.contains(where: { $0.path.hasSuffix(".safetensors") }) {
            return .mlx
        }
        return .unknown
    }

    static func detectQuantizationBits(info: HFModelInfo) -> Int? {
        let haystack = info.id.lowercased()
        let patterns: [(String, Int)] = [
            ("8bit", 8), ("8-bit", 8), ("int8", 8),
            ("4bit", 4), ("4-bit", 4), ("int4", 4),
            ("6bit", 6), ("3bit", 3), ("2bit", 2),
            ("bf16", 16), ("fp16", 16), ("f16", 16),
            ("fp32", 32), ("f32", 32)
        ]
        for (needle, bits) in patterns where haystack.contains(needle) {
            return bits
        }
        return nil
    }

    /// Heuristic parameter count from the repo name: "4B", "0.5B", "1.5b", "7b".
    static func detectParameterCount(info: HFModelInfo) -> Double? {
        let name = info.id
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)[bB](?:[^a-zA-Z]|$)"#) else {
            return nil
        }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let r = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return Double(name[r])
    }

    /// Files needed to run the model. For MLX: safetensors weights, JSON configs,
    /// tokenizer files, chat templates. Skips READMEs, images, git metadata.
    public static func neededFiles(info: HFModelInfo, format: ModelFormat) -> [HFSibling] {
        info.siblings.filter { sibling in
            let path = sibling.path
            let lowered = path.lowercased()
            if lowered.hasPrefix(".") { return false }            // .gitattributes, .gitignore
            if lowered == "readme.md" { return false }
            let imageExts = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"]
            if imageExts.contains(where: { lowered.hasSuffix($0) }) { return false }
            switch format {
            case .mlx:
                if lowered.hasSuffix(".safetensors") { return true }
                if lowered.hasSuffix(".json") { return true }
                if lowered.hasSuffix(".jinja") { return true }
                if lowered.hasSuffix(".txt") { return true }       // e.g. vocab/tokenizer txt
                if lowered.hasSuffix(".model") { return true }     // sentencepiece
                if lowered.hasSuffix(".tiktoken") || lowered.hasSuffix(".merges") { return true }
                return false
            case .gguf:
                return lowered.hasSuffix(".gguf")
            case .unknown:
                return true
            }
        }
    }

    static func neededFileBytes(info: HFModelInfo, format: ModelFormat) -> Int64 {
        neededFiles(info: info, format: format).reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
    }
}
