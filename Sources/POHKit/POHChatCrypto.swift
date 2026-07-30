import CryptoKit
import Foundation

/// chat-crypto — portable public-job chat encryption for the POH iOS SDK.
///
/// Public compute jobs are raced by miners the requester doesn't control, so the on-chain
/// record of the prompt/reply is sealed to the requester's X25519 key:
///
///     X25519 (ECDH) -> HKDF-SHA256 -> AES-256-GCM
///
/// Wire format is byte-identical to the node reference (poh-miner
/// `src/security/chat-crypto.js`) and the JS/Python/Rust/Android SDKs — see CHAT-CRYPTO.md.
/// Uses CryptoKit (iOS 13+, macOS 10.15+).
public enum POHChatCrypto {
    private static let sealInfo = Data("poh-chat-seal-v1".utf8)
    private static let scalarInfo = Data("poh-x25519-v1".utf8)

    /// A wallet's raw 32-byte X25519 encryption keypair (base64).
    public struct EncryptionKeypair {
        public let publicKeyB64: String
        public let privateKeyB64: String
    }

    /// A sealed chat envelope (all fields base64).
    public struct SealedEnvelope: Codable {
        public let v: Int
        public let alg: String
        public let epk: String
        public let iv: String
        public let ct: String

        public init(v: Int, alg: String, epk: String, iv: String, ct: String) {
            self.v = v; self.alg = alg; self.epk = epk; self.iv = iv; self.ct = ct
        }
    }

    public enum ChatCryptoError: Error {
        case badRecipientKey, badEnvelope, decrypt
    }

    private static func deriveKey(shared: SharedSecret, recipientPub: Data, epk: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: recipientPub + epk,
            sharedInfo: sealInfo,
            outputByteCount: 32
        )
    }

    /// Deterministically derive the wallet's X25519 keypair from a stable secret (its
    /// ed25519 signing private key PEM), matching the node.
    public static func deriveEncryptionKeypair(_ stableSecret: Data) throws -> EncryptionKeypair {
        let scalar = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: stableSecret),
            salt: Data(),
            info: scalarInfo,
            outputByteCount: 32
        )
        let scalarData = scalar.withUnsafeBytes { Data($0) }
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalarData)
        return EncryptionKeypair(
            publicKeyB64: priv.publicKey.rawRepresentation.base64EncodedString(),
            privateKeyB64: scalarData.base64EncodedString()
        )
    }

    public static func deriveEncryptionKeypair(_ stableSecret: String) throws -> EncryptionKeypair {
        try deriveEncryptionKeypair(Data(stableSecret.utf8))
    }

    /// Seal a plaintext to a recipient's raw X25519 public key (base64).
    public static func seal(recipientPubB64: String, plaintext: Data) throws -> SealedEnvelope {
        guard let recipientRaw = Data(base64Encoded: recipientPubB64), recipientRaw.count == 32 else {
            throw ChatCryptoError.badRecipientKey
        }
        let recipientPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientRaw)
        let esk = Curve25519.KeyAgreement.PrivateKey()
        let epk = esk.publicKey.rawRepresentation
        let shared = try esk.sharedSecretFromKeyAgreement(with: recipientPub)
        let key = deriveKey(shared: shared, recipientPub: recipientRaw, epk: epk)

        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        // Our wire format is ciphertext || 16-byte tag, with an explicit 12-byte nonce.
        let ct = sealedBox.ciphertext + sealedBox.tag
        let iv = Data(sealedBox.nonce)
        return SealedEnvelope(
            v: 1,
            alg: "x25519-hkdf-sha256-aes256gcm",
            epk: epk.base64EncodedString(),
            iv: iv.base64EncodedString(),
            ct: ct.base64EncodedString()
        )
    }

    public static func seal(recipientPubB64: String, plaintext: String) throws -> SealedEnvelope {
        try seal(recipientPubB64: recipientPubB64, plaintext: Data(plaintext.utf8))
    }

    /// Open an envelope with the recipient's raw X25519 private scalar (base64).
    public static func open(_ env: SealedEnvelope, privateScalarB64: String) throws -> String {
        guard env.v == 1,
              let scalar = Data(base64Encoded: privateScalarB64),
              let epk = Data(base64Encoded: env.epk),
              let iv = Data(base64Encoded: env.iv),
              let blob = Data(base64Encoded: env.ct), blob.count >= 16
        else { throw ChatCryptoError.badEnvelope }

        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
        let recipientPub = priv.publicKey.rawRepresentation
        let epkPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
        let shared = try priv.sharedSecretFromKeyAgreement(with: epkPub)
        let key = deriveKey(shared: shared, recipientPub: recipientPub, epk: epk)

        let ciphertext = blob.prefix(blob.count - 16)
        let tag = blob.suffix(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
        let pt = try AES.GCM.open(box, using: key)
        return String(decoding: pt, as: UTF8.self)
    }
}
