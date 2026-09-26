import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 hashing. Uses CryptoKit when available (Apple platforms) and a
/// small pure-Swift implementation otherwise (Linux without CryptoKit).
public enum SHA256 {
    public static func hash(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        return PureSHA256.hash(data)
        #endif
    }

    public static func hexDigest(_ data: Data) -> String {
        hash(data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hash a file incrementally without loading it into memory.
    public static func hexDigest(fileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PureSHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #endif
    }
}

/// Pure-Swift SHA-256 (FIPS 180-4). Streaming: `update` with chunks, then
/// `finalize`.
public struct PureSHA256: Sendable {
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var messageLength: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    public init() {}

    public static func hash(_ data: Data) -> Data {
        var h = PureSHA256()
        h.update(data)
        return Data(h.finalize())
    }

    public mutating func update(_ data: Data) {
        messageLength &+= UInt64(data.count)
        buffer.append(contentsOf: data)
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            buffer.removeFirst(64)
            compress(block: block)
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = messageLength &* 8
        buffer.append(0x80)
        while buffer.count % 64 != 56 {
            buffer.append(0)
        }
        for i in stride(from: 7, through: 0, by: -1) {
            buffer.append(UInt8((bitLength >> (i * 8)) & 0xff))
        }
        while buffer.count >= 64 {
            let block = Array(buffer.prefix(64))
            buffer.removeFirst(64)
            compress(block: block)
        }
        var out: [UInt8] = []
        for word in state {
            out.append(UInt8((word >> 24) & 0xff))
            out.append(UInt8((word >> 16) & 0xff))
            out.append(UInt8((word >> 8) & 0xff))
            out.append(UInt8(word & 0xff))
        }
        return out
    }

    private mutating func compress(block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(block[i * 4]) << 24
                | UInt32(block[i * 4 + 1]) << 16
                | UInt32(block[i * 4 + 2]) << 8
                | UInt32(block[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotated(right: 7) ^ w[i - 15].rotated(right: 18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotated(right: 17) ^ w[i - 2].rotated(right: 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<64 {
            let s1 = e.rotated(right: 6) ^ e.rotated(right: 11) ^ e.rotated(right: 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = a.rotated(right: 2) ^ a.rotated(right: 13) ^ a.rotated(right: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }

        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

private extension UInt32 {
    func rotated(right n: UInt32) -> UInt32 {
        (self >> n) | (self << (32 - n))
    }
}
