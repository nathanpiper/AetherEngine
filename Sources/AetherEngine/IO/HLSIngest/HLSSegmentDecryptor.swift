import Foundation
import CommonCrypto

/// AES-128-CBC clear-key decryption for HLS segments (EXT-X-KEY
/// METHOD=AES-128). This is the standard clear-key scheme used by FAST
/// providers (Pluto / Samsung TV+ etc.): a 16-byte key fetched in the
/// clear over HTTPS plus a per-segment IV, the whole TS segment
/// encrypted as one AES-CBC message with PKCS7 padding. It is NOT a DRM
/// system (no FairPlay/Widevine); decrypting it is ordinary HLS client
/// behaviour, the same step AVPlayer and ffmpeg perform natively.
enum HLSSegmentDecryptor {

    /// Decrypt one AES-128-CBC/PKCS7 segment. `key` and `iv` must each be
    /// exactly 16 bytes. Returns nil on a malformed key/IV length or a
    /// CommonCrypto failure (caller treats it as a terminal decrypt error
    /// and the host falls back to the server-muxed route).
    static func decryptAES128CBC(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }

        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var plaintext = Data(count: outputCapacity)
        var decryptedCount = 0
        let status = plaintext.withUnsafeMutableBytes { outBuf -> CCCryptorStatus in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES128,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, outputCapacity,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        plaintext.removeSubrange(decryptedCount..<plaintext.count)
        return plaintext
    }
}
