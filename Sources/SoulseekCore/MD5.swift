import Foundation

/// RFC 1321 MD5 implementation. Used for the login checksum field
/// (`md5(username + password)`); the protocol does not require it to be
/// cryptographically strong, and a self-contained implementation keeps
/// SoulseekCore dependency-free and Linux-testable.
public enum MD5 {
    public static func hexDigest(_ input: String) -> String {
        hexDigest(Data(input.utf8))
    }

    public static func hexDigest(_ data: Data) -> String {
        digest(data).map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let originalBitLength = UInt64(message.count) &* 8

        // Padding: 0x80 then zeros until length ≡ 56 (mod 64), then 8-byte little-endian bit length
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8((originalBitLength >> UInt64(shift)) & 0xFF))
        }

        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xEFCDAB89
        var c0: UInt32 = 0x98BADCFE
        var d0: UInt32 = 0x10325476

        var chunkStart = 0
        while chunkStart < message.count {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0 ..< 16 {
                var word: UInt32 = 0
                for byteIndex in 0 ..< 4 {
                    word |= UInt32(message[chunkStart + i * 4 + byteIndex]) << UInt32(byteIndex * 8)
                }
                m[i] = word
            }
            chunkStart += 64

            var a = a0
            var b = b0
            var c = c0
            var d = d0

            for i in 0 ..< 64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0 ..< 16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16 ..< 32:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 32 ..< 48:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }

                f = f &+ a &+ K[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ rotl(f, by: S[i])
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var output = [UInt8]()
        output.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                output.append(UInt8((word >> shift) & 0xFF))
            }
        }
        return output
    }

    private static func rotl(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static let S: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let K: [UInt32] = [
        0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE,
        0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
        0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE,
        0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
        0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA,
        0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
        0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED,
        0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
        0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C,
        0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
        0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05,
        0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
        0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039,
        0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
        0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1,
        0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
    ]
}
