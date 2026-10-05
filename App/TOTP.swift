import Foundation
import CryptoKit

/// The 6-digit code of a TOTP secret (RFC 6238: HMAC-SHA1, 30-second steps). Same parameters as openconnect's
/// `token-mode=totp`, so the code shown is the one openconnect computes when it connects. The `digits`, `period`
/// and `algorithm` parameters of an otpauth:// URL are not read.
enum TOTP {
    static let period = 30
    static let digits = 6

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// Base32 (RFC 4648) to bytes. Trailing "=" is tolerated; any other character makes it nil.
    static func base32Decode(_ input: String) -> Data? {
        var s = Substring(input.uppercased())
        while s.hasSuffix("=") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        var out = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for ch in s.utf8 {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        return out
    }

    /// The code at `date`, or nil if the secret is not valid Base32. Accepts the same forms as the settings field:
    /// a bare key, "base32:…", or the full otpauth:// URL.
    static func code(secret: String, at date: Date = Date()) -> String? {
        guard let key = base32Decode(ConfigStore.normalizeTOTP(secret)) else { return nil }
        let counter = UInt64(max(0, date.timeIntervalSince1970)) / UInt64(period)
        var message = counter.bigEndian
        let data = withUnsafeBytes(of: &message) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        var value = UInt32(mac[offset] & 0x7f) << 24
        value |= UInt32(mac[offset + 1]) << 16
        value |= UInt32(mac[offset + 2]) << 8
        value |= UInt32(mac[offset + 3])
        var modulus: UInt32 = 1
        for _ in 0..<digits { modulus *= 10 }
        return String(format: "%0\(digits)d", value % modulus)
    }

    /// Seconds until the current code changes (1…30).
    static func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(max(0, date.timeIntervalSince1970)) % period
    }
}
