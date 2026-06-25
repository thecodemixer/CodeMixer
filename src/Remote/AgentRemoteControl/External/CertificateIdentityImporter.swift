import Foundation
import Security
import CryptoKit

/// Security.framework boundary for importing PKCS#12 identities.
public enum CertificateIdentityImporter {

    public enum ImportError: Error, Sendable {
        case importFailed(OSStatus)
        case fingerprintUnavailable
    }

    public struct Bundle: @unchecked Sendable {
        public let identity: SecIdentity
        public let certificateDER: Data
        public let sha256Fingerprint: String
    }

    public static func importIdentity(p12Data: Data, password: String) throws -> Bundle {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let first = items.first,
              let untyped = first[kSecImportItemIdentity as String] else {
            throw ImportError.importFailed(status)
        }
        guard CFGetTypeID(untyped as CFTypeRef) == SecIdentityGetTypeID() else {
            throw ImportError.importFailed(status)
        }

        // SecPKCS12Import vends a CF object; the type ID guard above proves
        // this value is a SecIdentity before we bridge it back to Swift.
        let identity = unsafeDowncast(untyped as AnyObject, to: SecIdentity.self)

        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw ImportError.fingerprintUnavailable
        }
        let certDER = SecCertificateCopyData(cert) as Data
        let fingerprint = SHA256.hash(data: certDER)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
        return Bundle(identity: identity,
                      certificateDER: certDER,
                      sha256Fingerprint: fingerprint)
    }
}
