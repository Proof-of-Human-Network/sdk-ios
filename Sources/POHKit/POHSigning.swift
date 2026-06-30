import CryptoKit
import Foundation

/// Ed25519 signing utilities for PoH transactions.
///
/// Uses CryptoKit (iOS 13+, macOS 10.15+).
public enum POHSigning {

    // ── Private DER prefixes for PKCS8 / SPKI ────────────────────────────────

    private static let pkcs8Prefix: [UInt8] = [
        0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05,
        0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20
    ]
    private static let spkiPrefix: [UInt8] = [
        0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b,
        0x65, 0x70, 0x03, 0x21, 0x00
    ]

    // ── PEM helpers ───────────────────────────────────────────────────────────

    private static func pemToBytes(_ pem: String) throws -> Data {
        let stripped = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let data = Data(base64Encoded: stripped) else {
            throw POHError.decodingError(NSError(domain: "POHSigning", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid PEM base64"]))
        }
        return data
    }

    private static func bytesToPem(_ data: Data, type: String) -> String {
        let b64   = data.base64EncodedString()
        // wrap at 64 chars
        let lines = stride(from: 0, to: b64.count, by: 64).map { i -> String in
            let start = b64.index(b64.startIndex, offsetBy: i)
            let end   = b64.index(start, offsetBy: min(64, b64.count - i))
            return String(b64[start..<end])
        }.joined(separator: "\n")
        return "-----BEGIN \(type)-----\n\(lines)\n-----END \(type)-----\n"
    }

    // ── Key import / export ───────────────────────────────────────────────────

    private static func importPrivateKey(_ pem: String) throws -> Curve25519.Signing.PrivateKey {
        let der = try pemToBytes(pem)
        guard der.count >= 48 else {
            throw POHError.decodingError(NSError(domain: "POHSigning", code: 2, userInfo: [NSLocalizedDescriptionKey: "PKCS8 DER too short"]))
        }
        let rawBytes = der.subdata(in: 16..<48)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: rawBytes)
    }

    private static func exportPrivateKeyPem(_ key: Curve25519.Signing.PrivateKey) -> String {
        let der = Data(pkcs8Prefix) + key.rawRepresentation
        return bytesToPem(der, type: "PRIVATE KEY")
    }

    private static func exportPublicKeyPem(_ key: Curve25519.Signing.PublicKey) -> String {
        let der = Data(spkiPrefix) + key.rawRepresentation
        return bytesToPem(der, type: "PUBLIC KEY")
    }

    // ── Key generation ────────────────────────────────────────────────────────

    /// Derive the canonical poh address bound to an ed25519 SPKI PEM public key.
    public static func deriveAddressFromSigningKey(_ signingPublicKey: String) -> String {
        let digest = SHA256.hash(data: Data(signingPublicKey.utf8))
        let hex    = digest.map { String(format: "%02x", $0) }.joined()
        return "poh" + String(hex.prefix(40))
    }

    /// Generate a fresh Ed25519 keypair compatible with the PoH node.
    public static func generateKeyPair() -> POHKeyPair {
        let priv = Curve25519.Signing.PrivateKey()
        let pubPem = exportPublicKeyPem(priv.publicKey)
        return POHKeyPair(
            signingPrivateKey: exportPrivateKeyPem(priv),
            signingPublicKey:  pubPem,
            address:           deriveAddressFromSigningKey(pubPem)
        )
    }

    // ── Signing ───────────────────────────────────────────────────────────────

    /// Sign an arbitrary UTF-8 message with an Ed25519 private key (PKCS8 PEM).
    /// Returns a base64-encoded signature.
    public static func signData(_ message: String, privateKeyPem: String) throws -> String {
        let key  = try importPrivateKey(privateKeyPem)
        let sig  = try key.signature(for: Data(message.utf8))
        return sig.base64EncodedString()
    }

    /// Build the proof needed by ``POHClient/registerSigningKey(_:publicKeyPem:proof:)``.
    ///
    /// The proof is a base64 signature of the wallet address itself.
    public static func createSigningProof(walletAddress: String, privateKeyPem: String) throws -> String {
        return try signData(walletAddress, privateKeyPem: privateKeyPem)
    }

    /// Build the rotation proof required to replace an existing registered key.
    public static func createRotationProof(
        address: String,
        newSigningPublicKey: String,
        existingPrivateKeyPem: String
    ) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": "rotate-key",
            "address": address,
            "newSigningPublicKey": newSigningPublicKey,
        ], options: [.sortedKeys])
        guard let payloadStr = String(data: payload, encoding: .utf8) else {
            throw POHError.decodingError(NSError(domain: "POHSigning", code: 3))
        }
        return try signData(payloadStr, privateKeyPem: existingPrivateKeyPem)
    }

    // ── Transaction ───────────────────────────────────────────────────────────

    /// Escape a string for embedding in the canonical JSON payload below, matching
    /// JavaScript's `JSON.stringify` escaping exactly (`"`, `\`, and control characters).
    /// Required for `computeTxHash` to byte-for-byte match the node's own hash — the
    /// node recomputes this hash from the transaction's fields and rejects any
    /// transaction whose `txHash` doesn't match, so any escaping divergence (e.g. an
    /// unescaped `"` in a memo) would make the resulting transaction unsendable.
    private static func jsonEscape(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// Compute the SHA-256 transaction hash over canonical fields. Returns a lowercase hex string.
    public static func computeTxHash(
        from: String, to: String, amount: Int64, fee: Int64,
        nonce: Int64, timestamp: Int64, memo: String
    ) -> String {
        let canonical = "{\"from\":\"\(jsonEscape(from))\",\"to\":\"\(jsonEscape(to))\",\"amount\":\(amount),\"fee\":\(fee),\"nonce\":\(nonce),\"timestamp\":\(timestamp),\"memo\":\"\(jsonEscape(memo))\"}"
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // ── Job fee payment ──────────────────────────────────────────────────────

    /// Compute the canonical payment hash for a job fee. Binds the fee to one
    /// specific job + miner + amount + nonce, so a signature over it can't be
    /// replayed against a different job or a higher budget. Must byte-for-byte
    /// match the node's own `computeJobPaymentHash`.
    public static func computeJobPaymentHash(
        jobId: String, requesterAddress: String, minerAddress: String,
        amount: Int64, nonce: Int64
    ) -> String {
        let canonical = "{\"jobId\":\"\(jsonEscape(jobId))\",\"requesterAddress\":\"\(jsonEscape(requesterAddress))\",\"minerAddress\":\"\(jsonEscape(minerAddress))\",\"amount\":\(amount),\"nonce\":\(nonce)}"
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Sign a fee payment authorizing a fee-required job (skill execution, or a
    /// model/dataset compute job). The result (`txHash`, `signature`) goes in the
    /// `paymentTx` field of a `POST /job` request — the node verifies the
    /// signature and debits the requester's balance before it will run the job.
    public static func signJobPayment(
        jobId: String, requesterAddress: String, minerAddress: String,
        amount: Int64, nonce: Int64, privateKeyPem: String
    ) throws -> (txHash: String, signature: String) {
        let txHash = computeJobPaymentHash(
            jobId: jobId, requesterAddress: requesterAddress, minerAddress: minerAddress,
            amount: amount, nonce: nonce
        )
        let signature = try signData(txHash, privateKeyPem: privateKeyPem)
        return (txHash, signature)
    }

    /// Generate a client-side job id (`job-<millis>-<8 random hex chars>`), matching
    /// the shape the node itself would generate if `id` were omitted from the request.
    /// Fee-required jobs must fix the id before signing, since the payment proof is
    /// bound to it.
    public static func generateJobId() -> String {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let suffix = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return "job-\(millis)-\(suffix)"
    }

    /// Build an unsigned PoH transfer transaction.
    ///
    /// - Parameters:
    ///   - from:      Sender address (`poh...`).
    ///   - to:        Recipient address.
    ///   - amountPOH: Amount in POH (e.g. 1.5 → 1_500_000_000 μPOH).
    ///   - nonce:     Sender's current nonce + 1. Fetch via ``POHClient/getNonce(_:)``.
    ///   - fee:       Miner fee in μPOH (default 0).
    ///   - memo:      Optional memo string.
    public static func buildTransfer(
        from: String,
        to: String,
        amountPOH: Double,
        nonce: Int64,
        fee: Int64 = 0,
        memo: String = ""
    ) -> PohTx {
        let amount    = Int64(amountPOH * 1_000_000_000)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let txHash    = computeTxHash(from: from, to: to, amount: amount, fee: fee, nonce: nonce, timestamp: timestamp, memo: memo)
        return PohTx(
            from: from, to: to, amount: amount, fee: fee,
            nonce: nonce, timestamp: timestamp, memo: memo,
            txHash: txHash, signature: nil, signingPublicKey: nil
        )
    }

    /// Sign a transaction built by ``buildTransfer(from:to:amountPOH:nonce:fee:memo:)``.
    ///
    /// ```swift
    /// let kp     = POHSigning.generateKeyPair()
    /// let tx     = POHSigning.buildTransfer(from: myAddr, to: recipient, amountPOH: 5.0, nonce: nonce + 1)
    /// let signed = try POHSigning.signTransaction(tx, keyPair: kp)
    /// let result = try await poh.submitTransaction(signed)
    /// ```
    public static func signTransaction(_ tx: PohTx, keyPair: POHKeyPair) throws -> PohTx {
        guard let txHash = tx.txHash else {
            throw POHError.decodingError(NSError(domain: "POHSigning", code: 3, userInfo: [NSLocalizedDescriptionKey: "tx.txHash is nil — call buildTransfer() first"]))
        }
        let signature = try signData(txHash, privateKeyPem: keyPair.signingPrivateKey)
        var signed = tx
        signed.signature        = signature
        signed.signingPublicKey = keyPair.signingPublicKey
        return signed
    }

    /// Sign with explicit PEM keys (alternative to passing a ``POHKeyPair``).
    public static func signTransaction(_ tx: PohTx, privateKeyPem: String, publicKeyPem: String) throws -> PohTx {
        guard let txHash = tx.txHash else {
            throw POHError.decodingError(NSError(domain: "POHSigning", code: 3, userInfo: [NSLocalizedDescriptionKey: "tx.txHash is nil — call buildTransfer() first"]))
        }
        let signature = try signData(txHash, privateKeyPem: privateKeyPem)
        var signed = tx
        signed.signature        = signature
        signed.signingPublicKey = publicKeyPem
        return signed
    }
}
