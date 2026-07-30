import XCTest
@testable import POHKit

final class POHChatCryptoTests: XCTestCase {
    func testDeterministicKeypair() throws {
        let a = try POHChatCrypto.deriveEncryptionKeypair("same")
        let b = try POHChatCrypto.deriveEncryptionKeypair("same")
        XCTAssertEqual(a.publicKeyB64, b.publicKeyB64)
        XCTAssertNotEqual(try POHChatCrypto.deriveEncryptionKeypair("diff").publicKeyB64, a.publicKeyB64)
    }

    func testRoundTrip() throws {
        let kp = try POHChatCrypto.deriveEncryptionKeypair("swift-secret")
        let env = try POHChatCrypto.seal(recipientPubB64: kp.publicKeyB64, plaintext: "hello swift")
        XCTAssertEqual(try POHChatCrypto.open(env, privateScalarB64: kp.privateKeyB64), "hello swift")
    }

    // Byte-compat with the node reference: this envelope was produced by the node's
    // src/security/chat-crypto.js for deriveEncryptionKeypair("rust-interop").
    func testOpensNodeSealedEnvelope() throws {
        let kp = try POHChatCrypto.deriveEncryptionKeypair("rust-interop")
        XCTAssertEqual(kp.publicKeyB64, "XWeuTjf5gk1B9EUaRYB0mBaRRudIfFn2CZkcsFp2NWc=")
        let env = POHChatCrypto.SealedEnvelope(
            v: 1,
            alg: "x25519-hkdf-sha256-aes256gcm",
            epk: "9Jgr/SzalkizcEPDyTPgaWL0zreJPcpxPzkQA33GgSw=",
            iv: "5vNG7exFDLDJRdlb",
            ct: "B+2GpffQMNnXB0UhDhtBT5Vw7e3FJWnL/XMsTObXel7O26NtIAhv"
        )
        XCTAssertEqual(try POHChatCrypto.open(env, privateScalarB64: kp.privateKeyB64), "hello from node to rust")
    }

    func testWrongKeyFails() throws {
        let kp = try POHChatCrypto.deriveEncryptionKeypair("a")
        let other = try POHChatCrypto.deriveEncryptionKeypair("b")
        let env = try POHChatCrypto.seal(recipientPubB64: kp.publicKeyB64, plaintext: "x")
        XCTAssertThrowsError(try POHChatCrypto.open(env, privateScalarB64: other.privateKeyB64))
    }
}
