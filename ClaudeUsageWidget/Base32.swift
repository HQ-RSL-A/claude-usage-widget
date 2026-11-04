import Foundation

/// RFC 4648 base32 in lowercase with no `=` padding: the form Grok Bot names its saved files in.
enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func lowercaseNoPadding(_ data: Data) -> String {
        var output = ""
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0      // the bits not written out yet: always fewer than 5 between bytes
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[(buffer >> bitCount) & 0x1F])
            }
            buffer &= (1 << bitCount) - 1
        }
        if bitCount > 0 {
            output.append(alphabet[(buffer << (5 - bitCount)) & 0x1F])   // the last bits, padded with zeros on the right
        }
        return output
    }
}
