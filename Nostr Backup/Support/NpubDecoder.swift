import Foundation

enum NpubDecoder {
    static func publicKey(from npub: String) throws -> String {
        let normalized = npub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == normalized.lowercased(),
              let separator = normalized.lastIndex(of: "1") else {
            throw NostrImportError.invalidNpub
        }

        let prefix = String(normalized[..<separator])
        let encodedData = normalized[normalized.index(after: separator)...]
        guard prefix == "npub", encodedData.count >= 7 else {
            throw NostrImportError.invalidNpub
        }

        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let values = encodedData.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == encodedData.count,
              polymod(expand(prefix) + values) == 1 else {
            throw NostrImportError.invalidNpub
        }

        let payload = Array(values.dropLast(6))
        guard let bytes = convertBits(payload, from: 5, to: 8), bytes.count == 32 else {
            throw NostrImportError.invalidNpub
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func expand(_ prefix: String) -> [Int] {
        prefix.unicodeScalars.map { Int($0.value >> 5) } + [0] + prefix.unicodeScalars.map { Int($0.value & 31) }
    }

    private static func polymod(_ values: [Int]) -> Int {
        let generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        return values.reduce(1) { checksum, value in
            let top = checksum >> 25
            var next = (checksum & 0x1ffffff) << 5 ^ value
            for (index, generator) in generators.enumerated() where ((top >> index) & 1) == 1 {
                next ^= generator
            }
            return next
        }
    }

    private static func convertBits(_ values: [Int], from: Int, to: Int) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        let maxValue = (1 << to) - 1
        var result: [UInt8] = []

        for value in values {
            guard value >= 0, value >> from == 0 else { return nil }
            accumulator = (accumulator << from) | value
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((accumulator >> bits) & maxValue))
            }
        }

        return bits < from && ((accumulator << (to - bits)) & maxValue) == 0 ? result : nil
    }
}

enum NostrImportError: LocalizedError {
    case invalidNpub
    case noRelayResponded

    var errorDescription: String? {
        switch self {
        case .invalidNpub:
            return "Enter a valid lowercase npub."
        case .noRelayResponded:
            return "None of the configured relays responded. Try again later."
        }
    }
}
