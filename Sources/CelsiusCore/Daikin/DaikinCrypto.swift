import CommonCrypto
import Foundation
import Security

public enum DaikinRoute: Sendable, Equatable {
    case command
    case status
    case acstatus

    fileprivate var payloadOffset: Int {
        switch self {
        case .command: 16
        // Both local response layouts carry a one-byte prefix between the IV and ciphertext.
        case .status, .acstatus: 17
        }
    }
}

public enum DaikinCryptoError: Error, LocalizedError, Equatable, Sendable {
    case invalidKeySize
    case shortFrame
    case invalidCRC
    case cryptographicFailure
    case randomGenerationFailure

    public var errorDescription: String? {
        switch self {
        case .invalidKeySize: "The Daikin integration key has an unsupported size."
        case .shortFrame: "The Daikin response is incomplete."
        case .invalidCRC: "The Daikin response failed its integrity check."
        case .cryptographicFailure: "The Daikin response could not be decrypted. Check the integration key."
        case .randomGenerationFailure: "A secure request could not be prepared."
        }
    }
}

/// Daikin's local AES-CFB framing used by the Daikin Smart AC unit.
public enum DaikinCrypto {
    public static func encode(_ payload: Data, key: Data, iv: Data? = nil) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw DaikinCryptoError.invalidKeySize }
        let initializationVector: Data
        if let iv {
            guard iv.count == kCCBlockSizeAES128 else { throw DaikinCryptoError.cryptographicFailure }
            initializationVector = iv
        } else {
            var bytes = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DaikinCryptoError.randomGenerationFailure
            }
            initializationVector = Data(bytes)
        }
        var plaintext = Data(payload)
        plaintext.append(contentsOf: [0x42, 0x5a])
        let ciphertext = try crypt(plaintext, key: key, iv: initializationVector, operation: CCOperation(kCCEncrypt))
        var frame = Data(initializationVector)
        frame.append(ciphertext)
        let crc = crc16(frame)
        frame.append(UInt8(crc & 0xff))
        frame.append(UInt8((crc >> 8) & 0xff))
        return frame
    }

    public static func decode(_ frame: Data, key: Data, route: DaikinRoute) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw DaikinCryptoError.invalidKeySize }
        guard frame.count >= route.payloadOffset + 1 + 2 else { throw DaikinCryptoError.shortFrame }
        let content = frame.dropLast(2)
        let suppliedCRC = UInt16(frame[frame.count - 1]) << 8 | UInt16(frame[frame.count - 2])
        guard crc16(Data(content)) == suppliedCRC else { throw DaikinCryptoError.invalidCRC }
        let iv = Data(frame.prefix(16))
        let encrypted = Data(frame.dropFirst(route.payloadOffset).dropLast(2))
        guard !encrypted.isEmpty else { throw DaikinCryptoError.shortFrame }
        let plaintext = try crypt(encrypted, key: key, iv: iv, operation: CCOperation(kCCDecrypt))
        if plaintext.suffix(2) == Data([0x42, 0x5a]) { return Data(plaintext.dropLast(2)) }
        return plaintext
    }

    /// CRC-16/CCITT used by the local frame; the two transmitted bytes are little-endian.
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            let index = UInt8((crc >> 8) ^ UInt16(byte))
            crc = (crc << 8) ^ crcTable[Int(index)]
        }
        return ~crc
    }

    private static func crypt(_ input: Data, key: Data, iv: Data, operation: CCOperation) throws -> Data {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    operation, CCMode(kCCModeCFB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else { throw DaikinCryptoError.cryptographicFailure }
        defer { CCCryptorRelease(cryptor) }
        let capacity = input.count + kCCBlockSizeAES128
        var output = [UInt8](repeating: 0, count: capacity)
        var moved = 0
        let update = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCryptorUpdate(cryptor, inputBytes.baseAddress, input.count, outputBytes.baseAddress, capacity, &moved)
            }
        }
        guard update == kCCSuccess else { throw DaikinCryptoError.cryptographicFailure }
        var finalMoved = 0
        let final = output.withUnsafeMutableBytes { bytes in
            CCCryptorFinal(cryptor, bytes.baseAddress!.advanced(by: moved), capacity - moved, &finalMoved)
        }
        guard final == kCCSuccess else { throw DaikinCryptoError.cryptographicFailure }
        return Data(output.prefix(moved + finalMoved))
    }

    private static let crcTable: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value) << 8
        for _ in 0..<8 { crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        return crc
    }
}
