import CryptoKit
import Foundation
import Security

enum KDEConnectCryptoError: Error, LocalizedError {
    case keyGenerationFailed(String)
    case signingFailed(String)
    case certificateCreationFailed
    case identityLookupFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let detail):
            return "Failed to generate KDE Connect key pair: \(detail)"
        case .signingFailed(let detail):
            return "Failed to sign KDE Connect certificate: \(detail)"
        case .certificateCreationFailed:
            return "Failed to encode self-signed X.509 certificate"
        case .identityLookupFailed(let status):
            return "Failed to load KDE Connect TLS identity from Keychain (status \(status))"
        }
    }
}

struct KDEConnectLocalIdentity {
    let deviceId: String
    let identity: SecIdentity
    let certificate: SecCertificate
    let certificateDER: Data
    let fingerprintHex: String
}

enum KDEConnectCrypto {
    private static let keyLabelPrefix = "com.macgadgets.kdeconnect.key."
    private static let certLabelPrefix = "com.macgadgets.kdeconnect.cert."
    private static let savedCertDefaultsPrefix = "KDEConnect.rsa2048.certificateDER."

    /// Loads an existing stable TLS identity for `deviceId` or generates and stores a new one.
    /// KDE Connect requires the certificate's Common Name (CN) to strictly equal `deviceId`.
    static func loadOrCreateIdentity(deviceId: String) throws -> KDEConnectLocalIdentity {
        let certDefaultsKey = savedCertDefaultsPrefix + deviceId
        if let savedCertDER = UserDefaults.standard.data(forKey: certDefaultsKey),
           let cert = SecCertificateCreateWithData(nil, savedCertDER as CFData),
           extractCommonName(from: cert) == deviceId,
           let identity = findIdentity(matchingCertificateDER: savedCertDER) {
            return KDEConnectLocalIdentity(
                deviceId: deviceId,
                identity: identity,
                certificate: cert,
                certificateDER: savedCertDER,
                fingerprintHex: sha256Hex(of: savedCertDER)
            )
        }

        // Clean up any stale items for this deviceId before generating a new pair.
        deleteKeychainItems(for: deviceId)

        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: keyLabelPrefix + deviceId,
                kSecAttrApplicationTag as String: Data((keyLabelPrefix + deviceId).utf8)
            ]
        ]

        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &keyError) else {
            let msg = keyError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw KDEConnectCryptoError.keyGenerationFailed(msg)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KDEConnectCryptoError.keyGenerationFailed("SecKeyCopyPublicKey returned nil")
        }

        var pubError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &pubError) as Data? else {
            let msg = pubError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw KDEConnectCryptoError.keyGenerationFailed(msg)
        }

        let certDER = try buildSelfSignedCertificateDER(
            commonName: deviceId,
            rsaPublicKeyPKCS1: publicKeyData,
            privateKey: privateKey
        )

        guard let cert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw KDEConnectCryptoError.certificateCreationFailed
        }

        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: certLabelPrefix + deviceId
        ]
        let addStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            throw KDEConnectCryptoError.identityLookupFailed(addStatus)
        }

        UserDefaults.standard.set(certDER, forKey: certDefaultsKey)

        guard let identity = findIdentity(matchingCertificateDER: certDER) else {
            throw KDEConnectCryptoError.identityLookupFailed(errSecItemNotFound)
        }

        return KDEConnectLocalIdentity(
            deviceId: deviceId,
            identity: identity,
            certificate: cert,
            certificateDER: certDER,
            fingerprintHex: sha256Hex(of: certDER)
        )
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func formattedFingerprint(of data: Data) -> String {
        let hex = sha256Hex(of: data).uppercased()
        var groups: [String] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            groups.append(String(hex[idx..<next]))
            idx = next
        }
        return groups.prefix(4).joined(separator: " ")
    }

    static func extractCommonName(from certificate: SecCertificate) -> String? {
        var commonName: CFString?
        let status = SecCertificateCopyCommonName(certificate, &commonName)
        if status == errSecSuccess, let cn = commonName as String?, !cn.isEmpty {
            return cn
        }
        if let summary = SecCertificateCopySubjectSummary(certificate) as String?, !summary.isEmpty {
            return summary
        }
        return nil
    }

    private static func findIdentity(matchingCertificateDER targetDER: Data) -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            return nil
        }
        for identity in identities {
            var certRef: SecCertificate?
            if SecIdentityCopyCertificate(identity, &certRef) == errSecSuccess,
               let cert = certRef,
               (SecCertificateCopyData(cert) as Data) == targetDER {
                return identity
            }
        }
        return nil
    }

    private static func deleteKeychainItems(for deviceId: String) {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data((keyLabelPrefix + deviceId).utf8)
        ]
        SecItemDelete(keyQuery as CFDictionary)

        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabelPrefix + deviceId
        ]
        SecItemDelete(certQuery as CFDictionary)
    }

    // MARK: - Minimal ASN.1 DER X.509 v3 Certificate Builder (RSA 2048 + SHA-256)

    static func buildSelfSignedCertificateDER(
        commonName: String,
        rsaPublicKeyPKCS1: Data,
        privateKey: SecKey
    ) throws -> Data {
        // Version: [0] EXPLICIT INTEGER 2 (X.509 v3)
        let version = derExplicitTag(0, content: derInteger(Data([0x02])))

        // Serial Number: positive 16-byte random integer
        var serialBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        serialBytes[0] &= 0x7F
        if serialBytes[0] == 0 { serialBytes[0] = 0x01 }
        let serial = derInteger(Data(serialBytes))

        // Signature Algorithm: sha256WithRSAEncryption (1.2.840.113549.1.1.11) + NULL
        let sha256WithRSAOID = derOID([1, 2, 840, 113549, 1, 1, 11])
        let sigAlg = derSequence(sha256WithRSAOID + derNull())

        // Issuer & Subject: CN = commonName
        let cnOID = derOID([2, 5, 4, 3])
        let cnValue = derUTF8String(commonName)
        let atv = derSequence(cnOID + cnValue)
        let rdn = derSet(atv)
        let name = derSequence(rdn)

        // Validity: yesterday to +10 years (UTCTime)
        let now = Date()
        let notBefore = now.addingTimeInterval(-86400)
        let notAfter = now.addingTimeInterval(10 * 365 * 86400)
        let validity = derSequence(derUTCTime(notBefore) + derUTCTime(notAfter))

        // SubjectPublicKeyInfo: rsaEncryption (1.2.840.113549.1.1.1) + NULL
        let rsaEncryptionOID = derOID([1, 2, 840, 113549, 1, 1, 1])
        let spkiAlg = derSequence(rsaEncryptionOID + derNull())
        let spkiKey = derBitString(rsaPublicKeyPKCS1)
        let spki = derSequence(spkiAlg + spkiKey)

        // Extensions: [3] EXPLICIT SEQUENCE { BasicConstraints(CA=false) }
        let basicConstraints = derSequence(
            derOID([2, 5, 29, 19]) +
            derOctetString(derSequence(Data()))
        )
        let extensions = derExplicitTag(3, content: derSequence(basicConstraints))

        let tbsCertificate = derSequence(
            version +
            serial +
            sigAlg +
            name +
            validity +
            name +
            spki +
            extensions
        )

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbsCertificate as CFData,
            &signError
        ) as Data? else {
            let msg = signError?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw KDEConnectCryptoError.signingFailed(msg)
        }

        return derSequence(tbsCertificate + sigAlg + derBitString(signature))
    }

    private static func derNull() -> Data {
        Data([0x05, 0x00])
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 {
            return Data([UInt8(length)])
        }
        var bytes: [UInt8] = []
        var len = length
        while len > 0 {
            bytes.insert(UInt8(len & 0xFF), at: 0)
            len >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func derTLV(tag: UInt8, content: Data) -> Data {
        var out = Data([tag])
        out.append(derLength(content.count))
        out.append(content)
        return out
    }

    private static func derSequence(_ content: Data) -> Data {
        derTLV(tag: 0x30, content: content)
    }

    private static func derSet(_ content: Data) -> Data {
        derTLV(tag: 0x31, content: content)
    }

    private static func derExplicitTag(_ tagNumber: UInt8, content: Data) -> Data {
        derTLV(tag: 0xA0 | tagNumber, content: content)
    }

    private static func derInteger(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        while bytes.count > 1 && bytes[0] == 0x00 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, (first & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTLV(tag: 0x02, content: Data(bytes))
    }

    private static func derBitString(_ data: Data) -> Data {
        var content = Data([0x00])
        content.append(data)
        return derTLV(tag: 0x03, content: content)
    }

    private static func derOctetString(_ data: Data) -> Data {
        derTLV(tag: 0x04, content: data)
    }

    private static func derUTF8String(_ string: String) -> Data {
        derTLV(tag: 0x0C, content: Data(string.utf8))
    }

    private static func derUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return derTLV(tag: 0x17, content: Data(formatter.string(from: date).utf8))
    }

    private static func derOID(_ components: [UInt]) -> Data {
        precondition(components.count >= 2)
        var bytes: [UInt8] = [UInt8(components[0] * 40 + components[1])]
        for comp in components.dropFirst(2) {
            var value = comp
            var encoded: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                encoded.insert(UInt8((value & 0x7F) | 0x80), at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: encoded)
        }
        return derTLV(tag: 0x06, content: Data(bytes))
    }
}
