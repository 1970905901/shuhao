import Foundation
import CommonCrypto
import Security

enum CryptoBridge {
    /// Matches `QuickJS.java#__lx_native_call__utils_str2md5`: URL-decode the input first
    /// (preload.js#md5 wraps callers in `encodeURIComponent`), THEN MD5 the resulting UTF-8 bytes.
    /// Without the decode step, MD5(non-ASCII) differs from Android.
    static func md5(_ str: String) -> String {
        let decoded = str.removingPercentEncoding ?? str
        let data = Data(decoded.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func base64Encode(_ str: String) -> String {
        Data(str.utf8).base64EncodedString()
    }

    static func base64DecodeToBytes(_ b64: String) -> [UInt8]? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        return [UInt8](data)
    }

    /// AES encrypt. mode: "AES/CBC/PKCS7Padding" or "AES" (ECB / NoPadding).
    /// Inputs are base64 strings; output is base64.
    static func aesEncrypt(dataB64: String, keyB64: String, ivB64: String, mode: String) -> String? {
        guard let data = Data(base64Encoded: dataB64),
              let key = Data(base64Encoded: keyB64) else { return nil }
        let iv: Data
        if ivB64.isEmpty {
            iv = Data()
        } else {
            guard let parsed = Data(base64Encoded: ivB64) else { return nil }
            iv = parsed
        }
        var options: CCOptions = 0
        let workingData = data
        switch mode {
        case "AES/CBC/PKCS7Padding":
            options = CCOptions(kCCOptionPKCS7Padding)
        case "AES":
            // Android uses `Cipher.getInstance("AES/ECB/NoPadding")` which is STRICT —
            // throws BadPaddingException if data isn't a multiple of the block size, and the
            // caller catches → returns "". Match that: don't zero-pad, let CCCrypt fail.
            options = CCOptions(kCCOptionECBMode)
            if workingData.count % kCCBlockSizeAES128 != 0 { return nil }
        default:
            return nil
        }
        // IV padding: Android pads/truncates to 16 bytes with zeros (line AES.java#28-30).
        let finalIV: Data = {
            if iv.isEmpty { return iv }
            var fixed = Data(count: 16)
            iv.copyBytes(to: fixed.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self) },
                         count: min(iv.count, 16))
            return fixed
        }()

        let bufferSize = workingData.count + kCCBlockSizeAES128
        var output = Data(count: bufferSize)
        var outLen = 0

        let status = output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            workingData.withUnsafeBytes { dataBytes -> CCCryptorStatus in
                key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                    finalIV.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            options,
                            keyBytes.baseAddress, key.count,
                            finalIV.isEmpty ? nil : ivBytes.baseAddress,
                            dataBytes.baseAddress, workingData.count,
                            outBytes.baseAddress, bufferSize,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = outLen
        return output.base64EncodedString()
    }

    /// RSA encrypt with given PEM body (no headers, base64 only). Returns base64 ciphertext.
    /// padding: "RSA/ECB/NoPadding" or "RSA/ECB/OAEPWithSHA1AndMGF1Padding".
    static func rsaEncrypt(dataB64: String, pemBody: String, padding: String) -> String? {
        guard let plain = Data(base64Encoded: dataB64) else { return nil }
        let cleaned = pemBody.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: cleaned) else { return nil }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        var key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error)
        if key == nil {
            // Try stripping SubjectPublicKeyInfo wrapper
            if let stripped = stripSPKIWrapper(der) {
                key = SecKeyCreateWithData(stripped as CFData, attrs as CFDictionary, &error)
            }
        }
        guard let publicKey = key else { return nil }

        let algo: SecKeyAlgorithm
        switch padding {
        case "RSA/ECB/NoPadding":
            algo = .rsaEncryptionRaw
        case "RSA/ECB/OAEPWithSHA1AndMGF1Padding":
            algo = .rsaEncryptionOAEPSHA1
        default:
            return nil
        }
        guard let cipher = SecKeyCreateEncryptedData(publicKey, algo, plain as CFData, &error) as Data? else {
            return nil
        }
        return cipher.base64EncodedString()
    }

    /// Best-effort SPKI strip — returns the raw RSA modulus+exponent sequence if input was wrapped.
    private static func stripSPKIWrapper(_ der: Data) -> Data? {
        let bytes = [UInt8](der)
        // Look for the BIT STRING marker 0x03 at top level after the OID block; this is heuristic.
        // The wrapper is normally 24 bytes. Try skipping that.
        if bytes.count > 24 {
            return Data(bytes[24..<bytes.count])
        }
        return nil
    }
}
