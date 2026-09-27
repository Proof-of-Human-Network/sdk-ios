import XCTest
@testable import POHKit

final class DAIChatCryptoTests: XCTestCase {
    func testDeterministicKeypair() throws {
        let a = try DAIChatCrypto.deriveEncryptionKeypair("same")
        let b = try DAIChatCrypto.deriveEncryptionKeypair("same")
        XCTAssertEqual(a.publicKeyB64, b.publicKeyB64)
        XCTAssertNotEqual(try DAIChatCrypto.deriveEncryptionKeypair("diff").publicKeyB64, a.publicKeyB64)
    }

    func testRoundTrip() throws {
        let kp = try DAIChatCrypto.deriveEncryptionKeypair("swift-secret")
        let env = try DAIChatCrypto.seal(recipientPubB64: kp.publicKeyB64, plaintext: "hello swift")
        XCTAssertEqual(try DAIChatCrypto.open(env, privateScalarB64: kp.privateKeyB64), "hello swift")
    }

    // Byte-compat with the node reference: this envelope was produced by the node's
    // src/security/chat-crypto.js for deriveEncryptionKeypair("rust-interop").
    func testOpensNodeSealedEnvelope() throws {
        let kp = try DAIChatCrypto.deriveEncryptionKeypair("rust-interop")
        XCTAssertEqual(kp.publicKeyB64, "KEuWmZUz5CWxn2QsMVq2ViPk6AQw5ZpFP7KYwiraiRs=")
        let env = DAIChatCrypto.SealedEnvelope(
            v: 1,
            alg: "x25519-hkdf-sha256-aes256gcm",
            epk: "iEPANh2KxCPlu4HC29mjejV2w9WWRZQMKLv/jaWWX2Q=",
            iv: "ulySPK2YUEhQsL2X",
            ct: "eUxra8/2d5RYGWoBwCCM6C7o5SjZPmtiVHislyZRzhMqRc73eERb"
        )
        XCTAssertEqual(try DAIChatCrypto.open(env, privateScalarB64: kp.privateKeyB64), "hello from node to rust")
    }

    func testWrongKeyFails() throws {
        let kp = try DAIChatCrypto.deriveEncryptionKeypair("a")
        let other = try DAIChatCrypto.deriveEncryptionKeypair("b")
        let env = try DAIChatCrypto.seal(recipientPubB64: kp.publicKeyB64, plaintext: "x")
        XCTAssertThrowsError(try DAIChatCrypto.open(env, privateScalarB64: other.privateKeyB64))
    }
}
