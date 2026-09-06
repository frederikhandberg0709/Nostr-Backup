import Foundation

/// Decodes the event ID in a NIP-19 `nevent` identifier.
enum NeventDecoder {
    static func eventID(from reference: String) -> String? {
        let value = reference.hasPrefix("nostr:") ? String(reference.dropFirst("nostr:".count)) : reference
        guard value == value.lowercased(),
              let separator = value.lastIndex(of: "1") else {
            return nil
        }

        let prefix = String(value[..<separator])
        let encodedData = value[value.index(after: separator)...]
        guard prefix == "nevent", encodedData.count >= 7 else { return nil }

        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let values = encodedData.compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == encodedData.count,
              polymod(expand(prefix) + values) == 1,
              let payload = convertBits(Array(values.dropLast(6)), from: 5, to: 8) else {
            return nil
        }

        var index = 0
        while index + 2 <= payload.count {
            let type = payload[index]
            let length = Int(payload[index + 1])
            index += 2
            guard index + length <= payload.count else { return nil }
            if type == 0, length == 32 {
                return payload[index..<(index + length)].map { String(format: "%02x", $0) }.joined()
            }
            index += length
        }
        return nil
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
